import Foundation

/// OpenAI-compatible `/audio/transcriptions` (OpenAI, Groq, or any compatible server).
struct WhisperAPIClient {
    var baseURL: String
    var apiKey: String
    var model: String
    var language: String?
    var prompt: String?

    func transcribe(wav: Data) async throws -> String {
        var base = baseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/audio/transcriptions") else {
            throw TranscriptionError.missingConfiguration("The Whisper API URL is invalid.")
        }
        let boundary = "voiceflow-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        if let language { field("language", language) }
        if let prompt { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data.prefix(300), encoding: .utf8) ?? "no details"
            throw TranscriptionError.http(status, message)
        }
        guard let text = object?["text"] as? String else {
            throw TranscriptionError.processFailed("The Whisper API returned no text.")
        }
        return text
    }
}

/// Runs a local whisper.cpp binary (`brew install whisper-cpp` → `whisper-cli`).
enum WhisperCpp {
    static func transcribe(
        wav: Data, binary: String, model: String, language: String?, prompt: String?
    ) async throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-\(UUID().uuidString).wav")
        try wav.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var arguments = ["-m", model, "-f", file.path, "-nt", "-np", "-l", language ?? "auto"]
        if let prompt, !prompt.isEmpty { arguments += ["--prompt", prompt] }
        let args = arguments
        return try await Task.detached(priority: .userInitiated) {
            try run(binary: binary, arguments: args)
        }.value
    }

    private static func run(binary: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.processFailed("whisper.cpp exited with code \(process.terminationStatus).")
        }
        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(separator: "\n")
            .map { $0.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression) }
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
