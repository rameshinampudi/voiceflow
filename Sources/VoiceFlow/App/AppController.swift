import AVFoundation
import VoiceFlowCore
import AppKit

enum AppStatus: Equatable {
    case ready
    case listening(handsFree: Bool, command: Bool)
    case processing
    case needsAccessibility
    case preparing(String)

    var menuTitle: String {
        switch self {
        case .ready: return "VoiceFlow is ready"
        case let .listening(handsFree, command):
            return command ? "Listening for a command…" : (handsFree ? "Listening (hands-free)…" : "Listening…")
        case .processing: return "Transcribing…"
        case .needsAccessibility: return "Needs Accessibility permission"
        case let .preparing(detail): return detail
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "wind"
        case .listening: return "waveform"
        case .processing: return "ellipsis.circle"
        case .needsAccessibility: return "exclamationmark.triangle"
        case .preparing: return "arrow.down.circle"
        }
    }
}

/// Orchestrates one dictation: key → mic → transcript → AI edit → paste.
@MainActor
final class AppController {
    let settings: SettingsStore
    let history: HistoryStore
    let transcription = TranscriptionService()
    let pill = FlowPillController()

    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyMonitor()
    private var machine = HotkeyStateMachine()

    private var session: TranscriptionSession?
    private var capture: CaptureContext?
    private var captureError: Error?
    private var processingCount = 0
    private var mutedOutput = false
    private var muteWork: DispatchWorkItem?
    private var accessibilityPoll: Timer?
    private var reprepareWork: DispatchWorkItem?
    private(set) var lastInsertedText: String?

    var onStatusChange: ((AppStatus) -> Void)?
    var hotkeysActive: Bool { hotkeys.isRunning }
    var isHandsFree: Bool { machine.isHandsFree }

    private struct CaptureContext {
        var mode: DictationMode
        var handsFree = false
        var activated = false
        var bundleID: String?
        var appName: String?
        var pid: pid_t?
        var windowTitle: String?
        var precedingText: String?
        var selectedText: String?
        var selectionKnown = false
        var isSecureField = false
    }

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    // MARK: - Lifecycle

    func start() {
        recorder.onLevel = { [weak self] level in self?.pill.model.push(level: level) }
        hotkeys.side = settings.config.hotkeySide
        hotkeys.onEvent = { [weak self] event in self?.handle(event) ?? false }
        hotkeys.onPasteLast = { [weak self] in self?.pasteLast() }
        transcription.onAppleStateChange = { [weak self] _ in self?.publishStatus() }
        installHotkeys()
        Task { await transcription.prepare(config: settings.config) }
        publishStatus()
    }

    func shutdown() {
        cancelCapture(silent: true)
        restoreOutputMute()
        hotkeys.stop()
    }

    func settingsChanged(old: VoiceFlowConfig, new: VoiceFlowConfig) {
        hotkeys.side = new.hotkeySide
        if old.showIdleBar != new.showIdleBar { publishStatus() }
        if old.engine != new.engine || old.localeIdentifier != new.localeIdentifier {
            // Debounced: the language field changes on every keystroke.
            reprepareWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Task { await self.transcription.prepare(config: self.settings.config, force: true) }
            }
            reprepareWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    func reprepareEngine() {
        Task { await transcription.prepare(config: settings.config, force: true) }
    }

    private func installHotkeys() {
        if hotkeys.start() {
            Log.app.notice("Hotkey listener active (accessibility trusted: \(Permissions.accessibilityTrusted))")
            accessibilityPoll?.invalidate()
            accessibilityPoll = nil
            publishStatus()
            return
        }
        // Not trusted yet — keep checking until the user flips the switch in System Settings.
        guard accessibilityPoll == nil else { return }
        Log.app.notice("Hotkey listener not active: waiting for Accessibility permission")
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Permissions.accessibilityTrusted else { return }
                self.installHotkeys()
            }
        }
    }

    // MARK: - Hotkey state machine

    @discardableResult
    private func handle(_ event: HotkeyEvent) -> Bool {
        let result = machine.handle(event)
        for action in result.actions { perform(action) }
        return result.swallow
    }

    func toggleHandsFree() {
        handle(.toggleHandsFree)
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case let .startCapture(mode):
            beginCapture(mode: mode)
        case let .scheduleTick(delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.handle(.tick(time: ProcessInfo.processInfo.systemUptime))
            }
        case let .activate(mode, handsFree):
            activate(mode: mode, handsFree: handsFree)
        case let .modeChanged(mode):
            guard capture != nil else { return }
            capture?.mode = mode
            if capture?.activated == true {
                pill.show(.listening(command: mode == .command, handsFree: capture?.handsFree ?? false))
                readScreenContext()
                publishStatus()
            }
        case .finish:
            finish()
        case let .cancel(silent):
            cancelCapture(silent: silent)
        }
    }

    // MARK: - Capture

    private func beginCapture(mode: DictationMode) {
        captureError = nil
        switch Permissions.microphoneStatus {
        case .authorized:
            break
        case .notDetermined:
            machine.reset()
            Task { _ = await Permissions.requestMicrophone() }
            return
        default:
            // Report it only if the user actually holds the key (not on every ⌥ shortcut).
            captureError = TranscriptionError.missingConfiguration(
                "Microphone access is off. Turn it on in System Settings → Privacy → Microphone.")
            capture = CaptureContext(mode: mode)
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        capture = CaptureContext(
            mode: mode, bundleID: front?.bundleIdentifier, appName: front?.localizedName,
            pid: front?.processIdentifier)
        do {
            let newSession = try transcription.makeSession(config: settings.config)
            try recorder.start { buffer in newSession.append(buffer) }
            session = newSession
        } catch {
            Log.app.error("Capture failed to start: \(error.localizedDescription, privacy: .public)")
            captureError = error
        }
    }

    private func activate(mode: DictationMode, handsFree: Bool) {
        if let error = captureError {
            captureError = nil
            machine.reset()
            capture = nil
            recorder.stop()
            pill.flash(error.localizedDescription, isError: true)
            Sounds.error()
            return
        }
        guard session != nil, var current = capture else { return }
        current.activated = true
        current.handsFree = handsFree
        current.mode = mode
        capture = current

        pill.show(.listening(command: mode == .command, handsFree: handsFree))
        if settings.config.playSounds { Sounds.start() }
        if settings.config.muteAudioWhileDictating { scheduleMute() }
        readScreenContext()
        publishStatus()
    }

    /// Context from the focused field: text before the cursor, selection, window title.
    private func readScreenContext() {
        guard var current = capture else { return }
        if let pid = current.pid, current.windowTitle == nil {
            current.windowTitle = AXContext.focusedWindowTitle(pid: pid)
        }
        if let element = AXContext.focusedElement() {
            current.isSecureField = AXContext.isSecure(element)
            if !current.isSecureField {
                if settings.config.useScreenContext, current.precedingText == nil {
                    current.precedingText = AXContext.precedingText(element, maxCharacters: 600)
                }
                if current.mode == .command {
                    let selection = AXContext.selectedText(element)
                    current.selectionKnown = selection.known
                    current.selectedText = selection.text
                }
            }
        }
        capture = current
    }

    private func finish() {
        guard let activeSession = session, var current = capture else {
            cancelCapture(silent: true)
            return
        }
        let seconds = recorder.stop()
        session = nil
        capture = nil
        restoreOutputMute()

        guard seconds >= 0.3 else {
            activeSession.cancel()
            pill.rest()
            publishStatus()
            return
        }
        if settings.config.playSounds { Sounds.stop() }
        pill.show(.processing(command: current.mode == .command))
        processingCount += 1
        publishStatus()

        let config = settings.config
        Task { @MainActor in
            defer {
                processingCount -= 1
                publishStatus()
            }
            var transcript: String?
            do {
                let raw = try await activeSession.finish()
                transcript = raw
                if current.mode == .command, current.selectedText == nil, !current.selectionKnown {
                    current.selectedText = await TextInserter.copySelectionViaClipboard()
                }
                let category = AppClassifier.category(bundleID: current.bundleID, windowTitle: current.windowTitle)
                let context = DictationContext(
                    mode: current.mode, appName: current.appName, bundleID: current.bundleID,
                    windowTitle: config.useScreenContext ? current.windowTitle : nil, category: category,
                    precedingText: config.useScreenContext ? current.precedingText : nil,
                    selectedText: current.selectedText)
                let output = try await DictationPipeline.makeDefault(config: config)
                    .run(transcript: raw, context: context)

                let outcome = await TextInserter.insert(output.text, restoreClipboard: config.restoreClipboard)
                Log.app.notice("Dictation inserted: \(seconds, format: .fixed(precision: 1))s audio, \(raw.count) → \(output.text.count) chars, AI \(output.aiUsed)")
                lastInsertedText = output.text.trimmed
                if config.keepHistory, !current.isSecureField {
                    history.add(HistoryEntry(
                        appName: current.appName, mode: current.mode, rawText: raw,
                        finalText: output.text.trimmed, audioSeconds: seconds, aiUsed: output.aiUsed))
                }
                if let warning = output.warning {
                    pill.flash(warning, isError: true, seconds: 4)
                } else if outcome == .pastedAndKeptOnClipboard {
                    pill.flash("Also copied to the clipboard", isError: false, seconds: 1.6)
                } else {
                    pill.rest()
                }
            } catch PipelineError.emptyTranscript {
                pill.flash("No speech detected", isError: false, seconds: 1.4)
            } catch {
                Log.app.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
                // Never lose what was said: keep the raw transcript in History and for ⌃⌘V.
                if let raw = transcript?.trimmed, !raw.isEmpty {
                    lastInsertedText = raw
                    if config.keepHistory, !current.isSecureField {
                        history.add(HistoryEntry(
                            appName: current.appName, mode: current.mode, rawText: raw,
                            finalText: raw, audioSeconds: seconds, aiUsed: false))
                    }
                    pill.flash("\(error.localizedDescription) Your words are saved in History.", isError: true, seconds: 4)
                } else {
                    pill.flash(error.localizedDescription, isError: true, seconds: 4)
                }
                Sounds.error()
            }
        }
    }

    /// Copies a past dictation so it can be pasted anywhere with ⌘V.
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pill.flash("Copied — press ⌘V to paste anywhere", isError: false, seconds: 1.6)
    }

    private func cancelCapture(silent: Bool) {
        recorder.stop()
        session?.cancel()
        session = nil
        capture = nil
        captureError = nil
        restoreOutputMute()
        if !silent { pill.rest() }
        publishStatus()
    }

    func pasteLastFromMenu() { pasteLast() }

    private func pasteLast() {
        guard let text = lastInsertedText, !text.isEmpty else {
            pill.flash("Nothing dictated yet", isError: false, seconds: 1.4)
            return
        }
        Task { _ = await TextInserter.insert(text, restoreClipboard: settings.config.restoreClipboard) }
    }

    // MARK: - Mute other audio

    private func scheduleMute() {
        muteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session != nil else { return }
            if SystemAudio.isMuted() == false, SystemAudio.setMuted(true) {
                self.mutedOutput = true
            }
        }
        muteWork = work
        // After the start sound has played.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func restoreOutputMute() {
        muteWork?.cancel()
        muteWork = nil
        if mutedOutput {
            SystemAudio.setMuted(false)
            mutedOutput = false
        }
    }

    // MARK: - Status

    private func publishStatus() {
        let status = currentStatus
        onStatusChange?(status)
        pill.setIdle(idleStatus(for: status), visible: settings.config.showIdleBar)
    }

    private func idleStatus(for status: AppStatus) -> IdleStatus {
        if case .needsAccessibility = status {
            return .needsPermission("Allow Accessibility so ⌥ works — see VoiceFlow's menu")
        }
        if Permissions.microphoneStatus == .denied || Permissions.microphoneStatus == .restricted {
            return .needsPermission("Microphone access is off")
        }
        if case let .preparing(detail) = status { return .preparing(detail) }
        return .ready
    }

    var currentStatus: AppStatus {
        if !hotkeys.isRunning { return .needsAccessibility }
        if let capture, capture.activated {
            return .listening(handsFree: capture.handsFree, command: capture.mode == .command)
        }
        if processingCount > 0 { return .processing }
        if settings.config.engine == .appleOnDevice {
            switch transcription.appleState {
            case .preparing, .downloading: return .preparing(transcription.appleState.summary)
            default: break
            }
        }
        return .ready
    }
}
