import AVFoundation
import AirflowCore
import Foundation
import Speech

/// Headless modes for testing the pipeline without the microphone or UI:
///   Airflow --selftest                     permissions, engine and config status
///   Airflow --transcribe <audio file>      run a file through transcription + cleanup
///   Airflow --cleanup "<text>" [--app id]  run text through the editing step only
///   add --no-ai to skip Claude
enum CLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains { ["--selftest", "--transcribe", "--cleanup", "--help"].contains($0) }
    }

    static func run(_ arguments: [String]) -> Never {
        Task { @MainActor in
            let code = await main(arguments)
            exit(code)
        }
        dispatchMain()
    }

    @MainActor
    private static func main(_ arguments: [String]) async -> Int32 {
        var config = ConfigStore().load()
        if arguments.contains("--no-ai") { config.aiCleanupEnabled = false }
        let appID = value(after: "--app", in: arguments)

        if arguments.contains("--help") {
            print("usage: Airflow [--selftest] [--transcribe <file>] [--cleanup <text>] [--app <bundle id>] [--no-ai]")
            return 0
        }
        if arguments.contains("--selftest") {
            await selfTest(config: config)
            return 0
        }
        if let path = value(after: "--transcribe", in: arguments) {
            return await transcribe(path: path, config: config, appID: appID)
        }
        if let text = value(after: "--cleanup", in: arguments) {
            return await cleanup(text: text, raw: text, config: config, appID: appID)
        }
        return 2
    }

    @MainActor
    private static func selfTest(config: AirflowConfig) async {
        print("Config:        \(ConfigStore().fileURL.path)")
        print("Engine:        \(config.engine.label)")
        print("Language:      \(config.localeIdentifier.isEmpty ? "system (\(Locale.current.identifier))" : config.localeIdentifier)")
        print("Accessibility: \(Permissions.accessibilityTrusted ? "granted" : "NOT granted")")
        print("Microphone:    \(describe(Permissions.microphoneStatus))")
        print("SpeechTranscriber available: \(SpeechTranscriber.isAvailable)")
        let requested = config.localeIdentifier.isEmpty ? Locale.current : Locale(identifier: config.localeIdentifier)
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        print("Supported locale for \(requested.identifier): \(supported?.identifier ?? "none")")
        if let supported {
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            print("Model assets:  \(await AssetInventory.status(forModules: [module]))")
        }
        let key = config.effectiveAnthropicKey
        print("AI editing:    \(config.aiCleanupEnabled ? "on" : "off"), model \(config.claudeModel), key \(key.isEmpty ? "missing" : "set")")
    }

    @MainActor
    private static func transcribe(path: String, config: AirflowConfig, appID: String?) async -> Int32 {
        let service = TranscriptionService()
        service.onAppleStateChange = { state in print("[engine] \(state.summary)") }
        await service.prepare(config: config)
        do {
            let session = try service.makeSession(config: config)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let format = file.processingFormat
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { break }
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                session.append(buffer)
            }
            let started = Date()
            let raw = try await session.finish()
            print("Raw transcript (\(String(format: "%.2f", Date().timeIntervalSince(started)))s after end of audio):")
            print("  \(raw)")
            return await cleanup(text: raw, raw: raw, config: config, appID: appID)
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    private static func cleanup(text: String, raw: String, config: AirflowConfig, appID: String?) async -> Int32 {
        let category = AppClassifier.category(bundleID: appID, windowTitle: nil)
        let context = DictationContext(mode: .dictation, appName: appID, bundleID: appID, category: category)
        let started = Date()
        do {
            let output = try await DictationPipeline.makeDefault(config: config).run(transcript: text, context: context)
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            print("Final text (\(output.aiUsed ? "Claude \(config.claudeModel)" : "offline cleanup"), \(elapsed)s, style \(config.style(for: category).label)):")
            print("  \(output.text)")
            if let warning = output.warning { print("warning: \(warning)") }
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }
}
