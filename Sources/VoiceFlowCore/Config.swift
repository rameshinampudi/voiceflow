import Foundation

public extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Which Option key starts dictation.
public enum HotkeySide: String, Codable, CaseIterable, Sendable, Identifiable {
    case either, left, right
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .either: return "Either Option key (⌥)"
        case .left: return "Left Option key only"
        case .right: return "Right Option key only"
        }
    }
}

public enum TranscriptionEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case appleOnDevice, openAICompatible, whisperCpp
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .appleOnDevice: return "Apple on-device (private, free)"
        case .openAICompatible: return "Whisper API (OpenAI or Groq)"
        case .whisperCpp: return "Local whisper.cpp"
        }
    }
}

/// How the AI editor should shape the text — Wispr Flow calls these "styles".
public enum WritingStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case formal, casual, veryCasual, technical
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        case .technical: return "Technical"
        }
    }
    public var guidance: String {
        switch self {
        case .formal:
            return "Formal: complete sentences, standard capitalization and punctuation, professional tone. Don't add greetings or sign-offs that weren't spoken."
        case .casual:
            return "Casual: natural and conversational, standard capitalization, light punctuation. Keep contractions and the speaker's phrasing."
        case .veryCasual:
            return "Very casual: texting style. Mostly lowercase, minimal punctuation, no period at the very end."
        case .technical:
            return "Technical: keep code identifiers, file names, commands, flags and API names exact; write spoken identifiers in code form (\"user underscore id\" → user_id, \"camel case get user\" → getUser). For a short command or a single identifier, don't add a trailing period."
        }
    }
}

/// The kind of app the user is dictating into; picks the default style.
public enum AppCategory: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable, Identifiable {
    case email, workMessages, personalMessages, code, aiPrompt, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .email: return "Email"
        case .workMessages: return "Work messages"
        case .personalMessages: return "Personal messages"
        case .code: return "Code & terminal"
        case .aiPrompt: return "AI chats"
        case .other: return "Everything else"
        }
    }
    public var defaultStyle: WritingStyle {
        switch self {
        case .email: return .formal
        case .workMessages: return .casual
        case .personalMessages: return .casual
        case .code: return .technical
        case .aiPrompt: return .casual
        case .other: return .formal
        }
    }
}

public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// A forced spelling: whenever the recognizer produces `heard`, write `written`.
public struct Replacement: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var heard: String
    public var written: String
    public init(id: UUID = UUID(), heard: String, written: String) {
        self.id = id
        self.heard = heard
        self.written = written
    }
}

public struct VoiceFlowConfig: Codable, Equatable, Sendable {
    // General
    public var hotkeySide: HotkeySide = .either
    public var playSounds: Bool = true
    public var muteAudioWhileDictating: Bool = false
    public var restoreClipboard: Bool = true
    public var keepHistory: Bool = true
    /// Keep a small breathing dot at the bottom of the screen while VoiceFlow is ready.
    public var showIdleBar: Bool = true
    /// Open VoiceFlow automatically at login (and so after every restart).
    public var launchAtLogin: Bool = true

    // Transcription
    public var engine: TranscriptionEngineKind = .appleOnDevice
    /// Empty means the system language.
    public var localeIdentifier: String = ""
    public var whisperAPIBaseURL: String = "https://api.openai.com/v1"
    public var whisperAPIKey: String = ""
    public var whisperAPIModel: String = "gpt-4o-transcribe"
    public var whisperCppBinary: String = "/opt/homebrew/bin/whisper-cli"
    public var whisperCppModel: String = ""

    // AI editing (Claude)
    public var aiCleanupEnabled: Bool = true
    public var anthropicAPIKey: String = ""
    public var claudeModel: String = "claude-opus-5-5"
    public var claudeEffort: String = "low"
    public var useScreenContext: Bool = true
    public var customInstructions: String = ""
    public var styles: [AppCategory: WritingStyle] = VoiceFlowConfig.defaultStyles

    // Personalization
    public var vocabulary: [String] = []
    public var replacements: [Replacement] = []
    public var snippets: [Snippet] = []

    public init() {}

    public static let defaultStyles: [AppCategory: WritingStyle] =
        Dictionary(uniqueKeysWithValues: AppCategory.allCases.map { ($0, $0.defaultStyle) })

    public static let claudeModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    public static let effortLevels = ["low", "medium", "high"]

    public func style(for category: AppCategory) -> WritingStyle {
        styles[category] ?? category.defaultStyle
    }

    /// The key from Settings, or `ANTHROPIC_API_KEY` when launched from a shell.
    public var effectiveAnthropicKey: String {
        let configured = anthropicAPIKey.trimmed
        if !configured.isEmpty { return configured }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.trimmed ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case hotkeySide, playSounds, muteAudioWhileDictating, restoreClipboard, keepHistory, showIdleBar, launchAtLogin
        case engine, localeIdentifier, whisperAPIBaseURL, whisperAPIKey, whisperAPIModel
        case whisperCppBinary, whisperCppModel
        case aiCleanupEnabled, anthropicAPIKey, claudeModel, claudeEffort, useScreenContext
        case customInstructions, styles
        case vocabulary, replacements, snippets
    }

    /// Lenient decoding: missing or unknown values fall back to defaults, so old
    /// config files keep working as settings are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = VoiceFlowConfig()
        hotkeySide = value(.hotkeySide, d.hotkeySide)
        playSounds = value(.playSounds, d.playSounds)
        muteAudioWhileDictating = value(.muteAudioWhileDictating, d.muteAudioWhileDictating)
        restoreClipboard = value(.restoreClipboard, d.restoreClipboard)
        keepHistory = value(.keepHistory, d.keepHistory)
        showIdleBar = value(.showIdleBar, d.showIdleBar)
        launchAtLogin = value(.launchAtLogin, d.launchAtLogin)
        engine = value(.engine, d.engine)
        localeIdentifier = value(.localeIdentifier, d.localeIdentifier)
        whisperAPIBaseURL = value(.whisperAPIBaseURL, d.whisperAPIBaseURL)
        whisperAPIKey = value(.whisperAPIKey, d.whisperAPIKey)
        whisperAPIModel = value(.whisperAPIModel, d.whisperAPIModel)
        whisperCppBinary = value(.whisperCppBinary, d.whisperCppBinary)
        whisperCppModel = value(.whisperCppModel, d.whisperCppModel)
        aiCleanupEnabled = value(.aiCleanupEnabled, d.aiCleanupEnabled)
        anthropicAPIKey = value(.anthropicAPIKey, d.anthropicAPIKey)
        claudeModel = value(.claudeModel, d.claudeModel)
        claudeEffort = value(.claudeEffort, d.claudeEffort)
        useScreenContext = value(.useScreenContext, d.useScreenContext)
        customInstructions = value(.customInstructions, d.customInstructions)
        styles = value(.styles, d.styles)
        vocabulary = value(.vocabulary, d.vocabulary)
        replacements = value(.replacements, d.replacements)
        snippets = value(.snippets, d.snippets)
    }
}

/// Reads and writes `~/Library/Application Support/VoiceFlow/config.json` (mode 0600 — it holds API keys).
public final class ConfigStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("config.json") }

    public init(directory: URL = ConfigStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceFlow", isDirectory: true)
    }

    public func load() -> VoiceFlowConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(VoiceFlowConfig.self, from: data)
        else { return VoiceFlowConfig() }
        return config
    }

    public func save(_ config: VoiceFlowConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
