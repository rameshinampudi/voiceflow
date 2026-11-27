import VoiceFlowCore
import Foundation

private func body(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

func claudeChecks(_ t: Checks) {
    t.run("request uses structured output, effort and refusal fallbacks") {
        let request = try ClaudeRewriter(apiKey: "sk-test", model: "claude-opus-5-5", effort: "low")
            .makeRequest(system: "sys", user: "hello")
        t.equal(request.url, ClaudeRewriter.endpoint)
        t.equal(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        t.equal(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        t.equal(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let json = body(request)
        t.equal(json["model"] as? String, "claude-opus-5-5")
        t.equal(json["system"] as? String, "sys")
        t.equal(json["fallbacks"] as? String, "default")
        t.expect(json["temperature"] == nil, "temperature must not be sent")
        t.expect(json["thinking"] == nil, "thinking is always on for Opus 5.5; don't send it")
        let output = try t.require(json["output_config"] as? [String: Any])
        t.equal(output["effort"] as? String, "low")
        let format = try t.require(output["format"] as? [String: Any])
        t.equal(format["type"] as? String, "json_schema")
    }

    t.run("haiku has no server-side fallback") {
        let request = try ClaudeRewriter(apiKey: "k", model: "claude-haiku-5-5", effort: "low")
            .makeRequest(system: "s", user: "u")
        t.equal(request.value(forHTTPHeaderField: "anthropic-beta"), nil)
        t.expect(body(request)["fallbacks"] == nil)
    }

    t.run("missing key throws") {
        t.throwsError(ClaudeError.missingAPIKey) {
            _ = try ClaudeRewriter(apiKey: "  ", model: "claude-opus-5-5", effort: "low").makeRequest(system: "", user: "")
        }
    }

    t.run("parses the text field and skips thinking blocks") {
        let json = """
        {"stop_reason":"end_turn","content":[
          {"type":"thinking","thinking":"","signature":"x"},
          {"type":"text","text":"{\\"text\\":\\"Let's meet at 3 PM.\\"}"}]}
        """
        t.equal(try ClaudeRewriter.parseResponse(data: Data(json.utf8), statusCode: 200), "Let's meet at 3 PM.")
    }

    t.run("refusal and truncation are errors") {
        t.throwsError(ClaudeError.refusal) {
            _ = try ClaudeRewriter.parseResponse(data: Data(#"{"stop_reason":"refusal","content":[]}"#.utf8), statusCode: 200)
        }
        t.throwsError(ClaudeError.truncated) {
            _ = try ClaudeRewriter.parseResponse(data: Data(#"{"stop_reason":"max_tokens","content":[]}"#.utf8), statusCode: 200)
        }
    }

    t.run("http errors carry the API message") {
        let json = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        t.throwsError(ClaudeError.http(status: 401, message: "invalid x-api-key")) {
            _ = try ClaudeRewriter.parseResponse(data: Data(json.utf8), statusCode: 401)
        }
    }

    t.run("dictation message carries context and transcript") {
        let context = DictationContext(
            appName: "Slack", windowTitle: "#eng", category: .workMessages, precedingText: "Quick update:")
        let message = PromptBuilder.dictationUserMessage(
            transcript: "um we shipped it", context: context, style: .casual,
            vocabulary: ["Electrum", " "], customInstructions: "Use British spelling.")
        t.expect(message.contains("App: Slack (Work messages)"))
        t.expect(message.contains("Window title: #eng"))
        t.expect(message.contains("Writing style. Casual"))
        t.expect(message.contains("Vocabulary (use these spellings): Electrum\n"))
        t.expect(message.contains("Use British spelling."))
        t.expect(message.contains("<before_cursor>Quick update:</before_cursor>"))
        t.expect(message.hasSuffix("<transcript>\num we shipped it\n</transcript>"))
    }

    t.run("command message includes selection and instruction") {
        let context = DictationContext(mode: .command, appName: "Mail", category: .email, selectedText: "hey can u send it")
        let message = PromptBuilder.commandUserMessage(
            instruction: "make this more formal", context: context, vocabulary: [], customInstructions: "")
        t.expect(message.contains("<selected_text>\nhey can u send it\n</selected_text>"))
        t.expect(message.hasSuffix("<instruction>\nmake this more formal\n</instruction>"))
    }
}
