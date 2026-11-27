import Foundation

/// Something that turns (system prompt, user message) into edited text.
public protocol TextRewriter: Sendable {
    func rewrite(system: String, user: String) async throws -> String
}

public enum ClaudeError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case http(status: Int, message: String)
    case refusal
    case truncated
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an Anthropic API key in Settings → AI Editing."
        case let .http(status, message): return "Claude API error \(status): \(message)"
        case .refusal: return "Claude declined to edit this text."
        case .truncated: return "Claude's reply was cut off."
        case let .badResponse(detail): return "Unexpected reply from Claude: \(detail)"
        }
    }
}

/// Calls the Claude Messages API over raw HTTP (there is no official Swift SDK).
/// Output is constrained to `{"text": "..."}` with structured outputs so no preamble
/// can ever leak into the user's text field.
public struct ClaudeRewriter: TextRewriter {
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public var apiKey: String
    public var model: String
    public var effort: String
    public var timeout: TimeInterval
    public var maxTokens: Int

    public init(apiKey: String, model: String, effort: String, timeout: TimeInterval = 20, maxTokens: Int = 8192) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.timeout = timeout
        self.maxTokens = maxTokens
    }

    /// Server-side refusal fallbacks exist for Opus/Sonnet/Fable, not Haiku.
    public static func supportsServerFallback(_ model: String) -> Bool {
        !model.contains("haiku")
    }

    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string"]],
        "required": ["text"],
        "additionalProperties": false,
    ]

    public static func makeBody(model: String, effort: String, maxTokens: Int, system: String, user: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": outputSchema],
            ],
        ]
        if supportsServerFallback(model) {
            body["fallbacks"] = "default"
        }
        return body
    }

    public func makeRequest(system: String, user: String) throws -> URLRequest {
        guard !apiKey.trimmed.isEmpty else { throw ClaudeError.missingAPIKey }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey.trimmed, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if Self.supportsServerFallback(model) {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        let body = Self.makeBody(model: model, effort: effort, maxTokens: maxTokens, system: system, user: user)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func parseResponse(data: Data, statusCode: Int) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard statusCode == 200 else {
            let message = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data.prefix(300), encoding: .utf8) ?? "no details"
            throw ClaudeError.http(status: statusCode, message: message)
        }
        guard let object else { throw ClaudeError.badResponse("not JSON") }
        let stopReason = object["stop_reason"] as? String
        if stopReason == "refusal" { throw ClaudeError.refusal }
        if stopReason == "max_tokens" { throw ClaudeError.truncated }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let json = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = parsed["text"] as? String
        else { throw ClaudeError.badResponse("missing text field") }
        return result
    }

    public func rewrite(system: String, user: String) async throws -> String {
        let request = try makeRequest(system: system, user: user)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.parseResponse(data: data, statusCode: status)
    }
}
