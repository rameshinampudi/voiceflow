import AVFoundation

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    var errorDescription: String? { "No microphone input is available." }
}

/// Captures the default input device with a fresh AVAudioEngine per dictation
/// (so AirPods/USB mic switches never leave us with a stale format).
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var startedAt: Date?
    /// Normalized 0…1 input level, delivered on the main queue ~30×/s.
    var onLevel: ((Float) -> Void)?

    var isRunning: Bool { engine != nil }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInputDevice }

        let levelHandler = onLevel
        var lastLevelTime = CFAbsoluteTimeGetCurrent()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onBuffer(buffer)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLevelTime >= 1.0 / 30.0 {
                lastLevelTime = now
                let level = AudioRecorder.level(of: buffer)
                DispatchQueue.main.async { levelHandler?(level) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        startedAt = Date()
    }

    /// Stops capture and returns how long it ran.
    @discardableResult
    func stop() -> TimeInterval {
        guard let engine else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        return duration
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channels[0]
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (decibels + 55) / 45))
    }
}

/// Streaming sample-rate / channel conversion between two PCM formats.
final class PCMConverter {
    private let converter: AVAudioConverter
    let outputFormat: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.outputFormat = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                // .noDataNow (not .endOfStream) keeps resampler state for the next chunk.
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
