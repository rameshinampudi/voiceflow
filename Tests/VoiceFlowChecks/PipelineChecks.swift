import VoiceFlowCore
import Foundation

private struct FakeRewriter: TextRewriter {
    var reply: @Sendable (String, String) throws -> String
    func rewrite(system: String, user: String) async throws -> String { try reply(system, user) }
}

private struct Offline: Error, LocalizedError {
    var errorDescription: String? { "offline" }
}

func pipelineChecks(_ t: Checks) async {
    await t.runAsync("AI path keeps snippets exact and joins spacing") {
        var config = VoiceFlowConfig()
        config.snippets = [Snippet(trigger: "my calendar link", expansion: "https://cal.example/me")]
        let rewriter = FakeRewriter { system, user in
            guard system == PromptBuilder.dictationSystemPrompt, user.contains("Book time here ⟦S1⟧") else {
                return "WRONG PROMPT"
            }
            return "book time here: ⟦S1⟧"
        }
        let context = DictationContext(category: .workMessages, precedingText: "Sure,")
        let output = try await DictationPipeline(config: config, rewriter: rewriter)
            .run(transcript: "Book time here my calendar link", context: context)
        t.equal(output.text, " book time here: https://cal.example/me")
        t.expect(output.aiUsed)
        t.equal(output.warning, nil)
    }

    await t.runAsync("falls back to offline cleanup when Claude fails") {
        let output = try await DictationPipeline(config: VoiceFlowConfig(), rewriter: FakeRewriter { _, _ in throw Offline() })
            .run(transcript: "um, hello there", context: DictationContext())
        t.equal(output.text, "Hello there")
        t.expect(!output.aiUsed)
        t.expect(output.warning?.contains("offline") == true)
    }

    await t.runAsync("no key means offline cleanup") {
        let output = try await DictationPipeline(config: VoiceFlowConfig(), rewriter: nil)
            .run(transcript: "uh testing new line one two", context: DictationContext())
        t.equal(output.text, "Testing\nOne two")
    }

    await t.runAsync("empty transcript throws") {
        let pipeline = DictationPipeline(config: VoiceFlowConfig(), rewriter: nil)
        await t.throwsErrorAsync(PipelineError.emptyTranscript) {
            _ = try await pipeline.run(transcript: "  ", context: DictationContext())
        }
        await t.throwsErrorAsync(PipelineError.emptyTranscript) {
            _ = try await pipeline.run(transcript: "um", context: DictationContext())
        }
    }

    await t.runAsync("command mode needs AI") {
        await t.throwsErrorAsync(PipelineError.commandNeedsAI) {
            _ = try await DictationPipeline(config: VoiceFlowConfig(), rewriter: nil)
                .run(transcript: "make it shorter", context: DictationContext(mode: .command))
        }
    }

    await t.runAsync("command mode replaces the selection verbatim") {
        let rewriter = FakeRewriter { system, user in
            guard system == PromptBuilder.commandSystemPrompt,
                  user.contains("<selected_text>\nhey send it\n</selected_text>")
            else { return "WRONG PROMPT" }
            return "Could you please send it?"
        }
        let context = DictationContext(mode: .command, precedingText: "x", selectedText: "hey send it")
        let output = try await DictationPipeline(config: VoiceFlowConfig(), rewriter: rewriter)
            .run(transcript: "make this polite", context: context)
        t.equal(output.text, "Could you please send it?")
    }

    await t.runAsync("dictionary replacements run before AI") {
        var config = VoiceFlowConfig()
        config.replacements = [Replacement(heard: "hubble app", written: "Hubble")]
        let rewriter = FakeRewriter { _, user in
            user.contains("open Hubble now") ? "Open Hubble now." : "WRONG PROMPT"
        }
        let output = try await DictationPipeline(config: config, rewriter: rewriter)
            .run(transcript: "open hubble app now", context: DictationContext())
        t.equal(output.text, "Open Hubble now.")
    }

    t.run("makeDefault respects the toggle and the key") {
        var config = VoiceFlowConfig()
        config.anthropicAPIKey = "sk-x"
        t.expect(DictationPipeline.makeDefault(config: config).rewriter != nil)
        config.aiCleanupEnabled = false
        t.expect(DictationPipeline.makeDefault(config: config).rewriter == nil)
    }
}

func storageChecks(_ t: Checks) {
    t.run("partial config fills in defaults") {
        let json = #"{"hotkeySide":"right","engine":"nonsense","vocabulary":["Electrum"]}"#
        let config = try JSONDecoder().decode(VoiceFlowConfig.self, from: Data(json.utf8))
        t.equal(config.hotkeySide, .right)
        t.equal(config.engine, .appleOnDevice)
        t.equal(config.vocabulary, ["Electrum"])
        t.equal(config.claudeModel, "claude-opus-5-5")
        t.equal(config.style(for: .email), .formal)
    }

    t.run("config round-trips with private file permissions") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        var config = VoiceFlowConfig()
        config.styles[.code] = .casual
        config.snippets = [Snippet(trigger: "sig", expansion: "Thanks,\nAlex")]
        try store.save(config)
        t.equal(store.load(), config)
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        t.equal(mode, 0o600)
    }

    t.run("WAV header is well formed") {
        let wav = WAVEncoder.encode(samples: [0, 0.5, -1, 1], sampleRate: 16_000)
        t.equal(wav.count, 44 + 8)
        t.equal(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        t.equal(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
    }

    t.run("history stats and cap") {
        let store = HistoryStore(fileURL: nil, maxEntries: 2)
        let now = Date()
        store.add(HistoryEntry(date: now.addingTimeInterval(-86_400 * 2), appName: "A", mode: .dictation,
                               rawText: "", finalText: "one two", audioSeconds: 6, aiUsed: true))
        store.add(HistoryEntry(date: now, appName: "B", mode: .dictation,
                               rawText: "", finalText: "three four five six", audioSeconds: 6, aiUsed: true))
        store.add(HistoryEntry(date: now, appName: "C", mode: .dictation,
                               rawText: "", finalText: "seven eight", audioSeconds: 6, aiUsed: false))
        t.equal(store.entries.map(\.appName), ["B", "C"])
        let stats = store.stats(now: now)
        t.equal(stats.totalWords, 6)
        t.equal(stats.wordsToday, 6)
        t.equal(stats.averageWPM, 30)
    }

    t.run("history search is newest-first and covers text, transcript and app") {
        let store = HistoryStore(fileURL: nil)
        let first = HistoryEntry(appName: "Slack", mode: .dictation, rawText: "um ship it",
                                 finalText: "Ship it.", audioSeconds: 2, aiUsed: true)
        let second = HistoryEntry(appName: "Mail", mode: .dictation, rawText: "dear team",
                                  finalText: "Dear team,", audioSeconds: 2, aiUsed: true)
        store.add(first)
        store.add(second)
        t.equal(store.search("").map(\.appName), ["Mail", "Slack"])
        t.equal(store.search("", limit: 1).map(\.appName), ["Mail"])
        t.equal(store.search("ship").map(\.appName), ["Slack"])
        t.equal(store.search("UM SHIP").map(\.appName), ["Slack"])
        t.equal(store.search("mail").map(\.appName), ["Mail"])
        store.remove(id: first.id)
        t.equal(store.entries.map(\.appName), ["Mail"])
    }
}
