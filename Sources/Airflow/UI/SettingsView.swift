import AVFoundation
import AirflowCore
import Combine
import ServiceManagement
import SwiftUI

struct SettingsActions {
    var requestMicrophone: () -> Void
    var requestAccessibility: () -> Void
    var reprepareEngine: () -> Void
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var ui: UIState
    let actions: SettingsActions

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $ui.tab) {
            GeneralTab(store: store, ui: ui, actions: actions)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            TranscriptionTab(store: store, ui: ui, actions: actions)
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(SettingsTab.transcription)
            AIEditingTab(store: store)
                .tabItem { Label("AI Editing", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
            DictionaryTab(store: store)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag(SettingsTab.dictionary)
            HistoryTab(history: history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
        }
        .frame(minWidth: 660, minHeight: 560)
        .onReceive(refresh) { _ in ui.refreshPermissions() }
    }
}

// MARK: - General

// Note: `@State` is a macro in the macOS 27 SDK and the Command Line Tools don't ship
// its plugin, so view-local state lives in small ObservableObjects via `@StateObject`.

@MainActor
private final class LoginItemModel: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change login item: \(error.localizedDescription)"
        }
        self.enabled = SMAppService.mainApp.status == .enabled
    }
}

@MainActor
private final class DraftText: ObservableObject {
    @Published var text = ""
}

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var ui: UIState
    let actions: SettingsActions
    @StateObject private var login = LoginItemModel()

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    detail: "To hear you while you hold the key.",
                    granted: ui.microphoneStatus == .authorized,
                    buttonTitle: ui.microphoneStatus == .notDetermined ? "Allow…" : "Open Settings",
                    action: actions.requestMicrophone)
                PermissionRow(
                    title: "Accessibility",
                    detail: "To notice the Option key in any app and type text where your cursor is.",
                    granted: ui.accessibilityGranted,
                    buttonTitle: "Open Settings",
                    action: actions.requestAccessibility)
            }

            Section("Shortcut") {
                Picker("Dictation key", selection: $store.config.hotkeySide) {
                    ForEach(HotkeySide.allCases) { Text($0.label).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hold ⌥ and talk, release to insert.")
                    Text("Double-tap ⌥ for hands-free; tap ⌥ again to finish, esc to cancel.")
                    Text("Hold ⌥ and add ⌃ for Command Mode: select text and say what to change.")
                    Text("⌃⌘V pastes your last dictation again.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Play start and stop sounds", isOn: $store.config.playSounds)
                Toggle("Mute other audio while dictating", isOn: $store.config.muteAudioWhileDictating)
                Toggle("Restore my clipboard after inserting", isOn: $store.config.restoreClipboard)
                Toggle("Keep dictation history", isOn: $store.config.keepHistory)
                Toggle("Launch Airflow at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Text("Settings file: \(store.configPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(buttonTitle, action: action)
            }
        }
    }
}

// MARK: - Transcription

private struct TranscriptionTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var ui: UIState
    let actions: SettingsActions

    var body: some View {
        Form {
            Section("Speech-to-text engine") {
                Picker("Engine", selection: $store.config.engine) {
                    ForEach(TranscriptionEngineKind.allCases) { Text($0.label).tag($0) }
                }
                TextField("Language", text: $store.config.localeIdentifier, prompt: Text("System default (e.g. en-US, en-IN, hi-IN)"))
            }

            switch store.config.engine {
            case .appleOnDevice:
                Section("On-device model") {
                    Text(ui.engineStatus).foregroundStyle(.secondary)
                    Button("Check again", action: actions.reprepareEngine)
                    Text("Runs entirely on this Mac and transcribes while you talk, so text is ready the moment you let go.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .openAICompatible:
                Section("Whisper API") {
                    HStack {
                        Button("Use OpenAI") {
                            store.config.whisperAPIBaseURL = "https://api.openai.com/v1"
                            store.config.whisperAPIModel = "gpt-4o-transcribe"
                        }
                        Button("Use Groq") {
                            store.config.whisperAPIBaseURL = "https://api.groq.com/openai/v1"
                            store.config.whisperAPIModel = "whisper-large-v3-turbo"
                        }
                    }
                    TextField("Base URL", text: $store.config.whisperAPIBaseURL)
                    SecureField("API key", text: $store.config.whisperAPIKey)
                    TextField("Model", text: $store.config.whisperAPIModel)
                    Text("Audio is uploaded after you release the key. Languages are auto-detected when the language field is empty.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .whisperCpp:
                Section("whisper.cpp") {
                    TextField("whisper-cli path", text: $store.config.whisperCppBinary)
                    TextField("Model file (.bin)", text: $store.config.whisperCppModel, prompt: Text("~/models/ggml-large-v3-turbo.bin"))
                    Text("Install with `brew install whisper-cpp`, then download a ggml model (large-v3-turbo is a good balance) from huggingface.co/ggerganov/whisper.cpp.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI editing

private struct AIEditingTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Claude") {
                Toggle("Clean up and format with Claude", isOn: $store.config.aiCleanupEnabled)
                SecureField("Anthropic API key", text: $store.config.anthropicAPIKey, prompt: Text("sk-ant-…"))
                Picker("Model", selection: $store.config.claudeModel) {
                    ForEach(AirflowConfig.claudeModels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Effort", selection: $store.config.claudeEffort) {
                    ForEach(AirflowConfig.effortLevels, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Toggle("Use the text around my cursor as context", isOn: $store.config.useScreenContext)
                Text("Claude removes filler words, applies your self-corrections (\"at 2, no, 3\"), fixes punctuation and formats lists. Opus 5.5 is the most accurate; Haiku 5.5 is the fastest and cheapest. Without a key, Airflow does basic offline cleanup. Command Mode needs a key.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Style per app") {
                ForEach(AppCategory.allCases) { category in
                    Picker(category.label, selection: styleBinding(category)) {
                        ForEach(WritingStyle.allCases) { Text($0.label).tag($0) }
                    }
                }
            }

            Section("Custom instructions") {
                TextEditor(text: $store.config.customInstructions)
                    .font(.body)
                    .frame(minHeight: 70)
                Text("For example: \"Use British spelling.\" or \"Never use em dashes.\"")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func styleBinding(_ category: AppCategory) -> Binding<WritingStyle> {
        Binding(
            get: { store.config.style(for: category) },
            set: { store.config.styles[category] = $0 })
    }
}

// MARK: - Dictionary & snippets

private struct DictionaryTab: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var draft = DraftText()

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Add a word, name or acronym", text: $draft.text)
                        .onSubmit(addWord)
                    Button("Add", action: addWord).disabled(draft.text.trimmed.isEmpty)
                }
                ForEach(store.config.vocabulary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        RemoveButton { store.config.vocabulary.removeAll { $0 == word } }
                    }
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Names and jargon the recognizer and Claude should spell your way.")
            }

            Section {
                ForEach($store.config.replacements) { $item in
                    HStack {
                        TextField("When I say", text: $item.heard)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Write", text: $item.written)
                        RemoveButton { store.config.replacements.removeAll { $0.id == item.id } }
                    }
                }
                Button("Add replacement") {
                    store.config.replacements.append(Replacement(heard: "", written: ""))
                }
            } header: {
                Text("Replacements")
            } footer: {
                Text("Forced spellings, e.g. \"p m s engine\" → pms_engine.")
            }

            Section {
                ForEach($store.config.snippets) { $item in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("Say", text: $item.trigger)
                            RemoveButton { store.config.snippets.removeAll { $0.id == item.id } }
                        }
                        TextField("Insert", text: $item.expansion, axis: .vertical)
                            .lineLimit(1...4)
                    }
                }
                Button("Add snippet") {
                    store.config.snippets.append(Snippet(trigger: "", expansion: ""))
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Say the phrase and Airflow inserts the full text exactly, e.g. \"my calendar link\".")
            }
        }
        .formStyle(.grouped)
    }

    private func addWord() {
        let word = draft.text.trimmed
        guard !word.isEmpty, !store.config.vocabulary.contains(word) else { return }
        store.config.vocabulary.append(word)
        draft.text = ""
    }
}

private struct RemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
    }
}

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject var history: HistoryStore
    @StateObject private var search = DraftText()

    var body: some View {
        let stats = history.stats()
        let results = history.search(search.text)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 28) {
                StatView(title: "Words today", value: "\(stats.wordsToday)")
                StatView(title: "Total words", value: "\(stats.totalWords)")
                StatView(title: "Average speed", value: "\(stats.averageWPM) wpm")
                Spacer()
                Button("Clear History", role: .destructive) { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search everything you've said", text: $search.text)
                    .textFieldStyle(.roundedBorder)
            }
            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No dictations yet", systemImage: "waveform",
                    description: Text("Hold ⌥ anywhere and start talking. Everything you say is kept here to copy and paste anywhere."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: search.text)
            } else {
                List(results) { entry in
                    HistoryRow(entry: entry) { history.remove(id: entry.id) }
                }
            }
        }
        .padding()
    }
}

private struct StatView: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.appName ?? "Unknown app").font(.caption.weight(.semibold))
                if entry.mode == .command {
                    Text("command").font(.caption2).padding(.horizontal, 5)
                        .background(Capsule().fill(Color.purple.opacity(0.2)))
                }
                if !entry.aiUsed {
                    Text("offline cleanup").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Button { copy(entry.finalText) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy — then ⌘V anywhere")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Delete from history")
            }
            Text(entry.finalText).textSelection(.enabled)
            if entry.rawText.trimmed != entry.finalText.trimmed {
                Text(entry.rawText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy") { copy(entry.finalText) }
            Button("Copy Original Transcript") { copy(entry.rawText) }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
