import AVFoundation
import Foundation
import Speech

/// Apple's on-device SpeechAnalyzer (macOS 26+). Streams audio while you talk, so
/// by the time the key is released most of the transcript is already done.
final class AppleSpeechEngine {
    struct Prepared {
        let locale: Locale
        let useSpeechTranscriber: Bool
        let format: AVAudioFormat
    }

    private(set) var prepared: Prepared?

    func prepare(localeID: String, onProgress: @escaping (Double) -> Void) async throws -> Prepared {
        let requested = localeID.trimmingCharacters(in: .whitespaces).isEmpty
            ? Locale.current : Locale(identifier: localeID)

        // Preferred: the newer SpeechTranscriber model (better accuracy, built-in punctuation).
        if SpeechTranscriber.isAvailable {
            var locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
            if locale == nil, localeID.trimmed.isEmpty {
                locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            }
            if let locale {
                let module = SpeechTranscriber(locale: locale, preset: .transcription)
                return try await finishPreparing(module: module, locale: locale, transcriber: true, onProgress: onProgress)
            }
        }
        // Fallback: the dictation model, which covers more locales and older hardware.
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            let module = DictationTranscriber(locale: locale, preset: .longDictation)
            return try await finishPreparing(module: module, locale: locale, transcriber: false, onProgress: onProgress)
        }
        throw TranscriptionError.unsupportedLocale(requested.identifier)
    }

    func makeSession(vocabulary: [String]) throws -> TranscriptionSession {
        guard let prepared else { throw TranscriptionError.notReady("The speech model isn't ready yet.") }
        return AppleSpeechSession(prepared: prepared, vocabulary: vocabulary)
    }

    private func finishPreparing(
        module: any SpeechModule, locale: Locale, transcriber: Bool, onProgress: @escaping (Double) -> Void
    ) async throws -> Prepared {
        try await Self.ensureAssets(for: [module], locale: locale, onProgress: onProgress)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriptionError.engineUnavailable("No audio format is compatible with the speech model.")
        }
        await Self.warmUp(module: module, format: format)
        let result = Prepared(locale: locale, useSpeechTranscriber: transcriber, format: format)
        prepared = result
        return result
    }

    private static func ensureAssets(
        for modules: [any SpeechModule], locale: Locale, onProgress: @escaping (Double) -> Void
    ) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .installed: return
        case .unsupported: throw TranscriptionError.unsupportedLocale(locale.identifier)
        default: break
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        let progress = request.progress
        let poller = Task {
            while !Task.isCancelled {
                onProgress(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { poller.cancel() }
        try await request.downloadAndInstall()
        onProgress(1)
    }

    /// Loads the model once so the first real dictation doesn't pay for it.
    private static func warmUp(module: any SpeechModule, format: AVAudioFormat) async {
        let analyzer = SpeechAnalyzer(
            modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try? await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
    }
}

final class AppleSpeechSession: TranscriptionSession {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let resultsTask: Task<String, Error>
    private let startTask: Task<Void, Error>
    private let targetFormat: AVAudioFormat
    private var converter: PCMConverter?  // audio thread only

    init(prepared: AppleSpeechEngine.Prepared, vocabulary: [String]) {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.targetFormat = prepared.format

        let module: any SpeechModule
        if prepared.useSpeechTranscriber {
            let transcriber = SpeechTranscriber(locale: prepared.locale, preset: .transcription)
            module = transcriber
            resultsTask = Task {
                var parts: [String] = []
                for try await result in transcriber.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
                return AppleSpeechSession.join(parts)
            }
        } else {
            let transcriber = DictationTranscriber(locale: prepared.locale, preset: .longDictation)
            module = transcriber
            resultsTask = Task {
                var parts: [String] = []
                for try await result in transcriber.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
                return AppleSpeechSession.join(parts)
            }
        }

        let analyzer = SpeechAnalyzer(
            modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        startTask = Task {
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try? await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: stream)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil { converter = PCMConverter(from: buffer.format, to: targetFormat) }
        guard let converted = converter?.convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws -> String {
        continuation.finish()
        try await startTask.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultsTask.value
    }

    func cancel() {
        continuation.finish()
        resultsTask.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    static func join(_ parts: [String]) -> String {
        parts.map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
