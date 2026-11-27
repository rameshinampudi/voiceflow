import AVFoundation
import VoiceFlowCore
import Foundation

/// One dictation's worth of audio → text. `append` is called on the audio thread.
protocol TranscriptionSession: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel()
}

enum TranscriptionError: LocalizedError {
    case notReady(String)
    case unsupportedLocale(String)
    case engineUnavailable(String)
    case missingConfiguration(String)
    case processFailed(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case let .notReady(message): return message
        case let .unsupportedLocale(id): return "On-device speech doesn't support “\(id)”. Pick another language in Settings."
        case let .engineUnavailable(message): return message
        case let .missingConfiguration(message): return message
        case let .processFailed(message): return message
        case let .http(status, message): return "Transcription API error \(status): \(message)"
        }
    }
}

/// Picks the configured engine and keeps the on-device model ready.
@MainActor
final class TranscriptionService {
    enum AppleState: Equatable {
        case idle, preparing, downloading(Double), ready(String), failed(String)

        var summary: String {
            switch self {
            case .idle: return "Not prepared yet"
            case .preparing: return "Preparing on-device model…"
            case let .downloading(fraction): return "Downloading speech model… \(Int(fraction * 100))%"
            case let .ready(locale): return "On-device model ready (\(locale))"
            case let .failed(message): return "On-device model unavailable: \(message)"
            }
        }
    }

    private let apple = AppleSpeechEngine()
    private var preparedFor: String?
    private(set) var appleState: AppleState = .idle {
        didSet { if appleState != oldValue { onAppleStateChange?(appleState) } }
    }
    var onAppleStateChange: ((AppleState) -> Void)?

    func prepare(config: VoiceFlowConfig, force: Bool = false) async {
        guard config.engine == .appleOnDevice else { return }
        if !force, preparedFor == config.localeIdentifier, case .ready = appleState { return }
        if case .preparing = appleState, !force { return }
        appleState = .preparing
        do {
            let prepared = try await apple.prepare(localeID: config.localeIdentifier) { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    switch self.appleState {
                    case .preparing, .downloading: self.appleState = .downloading(fraction)
                    default: break
                    }
                }
            }
            preparedFor = config.localeIdentifier
            appleState = .ready(prepared.locale.identifier)
        } catch {
            appleState = .failed(error.localizedDescription)
        }
    }

    func makeSession(config: VoiceFlowConfig) throws -> TranscriptionSession {
        let language = Self.languageCode(config.localeIdentifier)
        let vocabulary = config.vocabulary.map(\.trimmed).filter { !$0.isEmpty }
        let prompt = vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ")

        switch config.engine {
        case .appleOnDevice:
            switch appleState {
            case .ready:
                return try apple.makeSession(vocabulary: vocabulary)
            case let .downloading(fraction):
                throw TranscriptionError.notReady("Downloading the speech model (\(Int(fraction * 100))%)…")
            case let .failed(message):
                Task { await prepare(config: config, force: true) }
                throw TranscriptionError.notReady(message)
            case .idle, .preparing:
                Task { await prepare(config: config) }
                throw TranscriptionError.notReady("Preparing the speech model…")
            }

        case .openAICompatible:
            let key = config.whisperAPIKey.trimmed
            guard !key.isEmpty else {
                throw TranscriptionError.missingConfiguration("Add a Whisper API key in Settings → Transcription.")
            }
            let client = WhisperAPIClient(
                baseURL: config.whisperAPIBaseURL, apiKey: key, model: config.whisperAPIModel,
                language: language, prompt: prompt)
            return BufferedSession { wav in try await client.transcribe(wav: wav) }

        case .whisperCpp:
            let binary = config.whisperCppBinary.trimmed
            let model = (config.whisperCppModel.trimmed as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: binary) else {
                throw TranscriptionError.missingConfiguration(
                    "whisper.cpp not found at \(binary). Install it with `brew install whisper-cpp`.")
            }
            guard FileManager.default.fileExists(atPath: model) else {
                throw TranscriptionError.missingConfiguration("Choose a whisper.cpp model file in Settings → Transcription.")
            }
            return BufferedSession { wav in
                try await WhisperCpp.transcribe(wav: wav, binary: binary, model: model, language: language, prompt: prompt)
            }
        }
    }

    static func languageCode(_ identifier: String) -> String? {
        let id = identifier.trimmed
        guard !id.isEmpty else { return nil }
        return Locale(identifier: id).language.languageCode?.identifier
    }
}

/// Collects 16 kHz mono audio, then hands a WAV to a batch transcriber when the key is released.
final class BufferedSession: TranscriptionSession {
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: PCMConverter?
    private let transcribe: (Data) async throws -> String

    init(transcribe: @escaping (Data) async throws -> String) {
        self.transcribe = transcribe
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil { converter = PCMConverter(from: buffer.format, to: Self.format) }
        guard let converted = converter?.convert(buffer), let channel = converted.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func finish() async throws -> String {
        let captured = lock.withLock { samples }
        guard captured.count > 16_000 / 4 else { return "" }  // < 0.25 s
        return try await transcribe(WAVEncoder.encode(samples: captured, sampleRate: 16_000))
    }

    func cancel() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}
