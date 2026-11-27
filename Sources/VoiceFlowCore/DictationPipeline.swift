import Foundation

public struct PipelineOutput: Equatable, Sendable {
    /// Text to insert (may start with a space to join the text before the cursor).
    public var text: String
    public var aiUsed: Bool
    /// Shown to the user when we had to fall back (e.g. the API was unreachable).
    public var warning: String?
}

public enum PipelineError: Error, LocalizedError, Equatable {
    case emptyTranscript
    case commandNeedsAI

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "No speech detected"
        case .commandNeedsAI: return "Command Mode needs AI editing — add an Anthropic API key in Settings."
        }
    }
}

/// Raw transcript → final text: dictionary, snippets, AI editing (or offline cleanup), spacing.
public struct DictationPipeline: Sendable {
    public var config: VoiceFlowConfig
    public var rewriter: TextRewriter?

    public init(config: VoiceFlowConfig, rewriter: TextRewriter?) {
        self.config = config
        self.rewriter = rewriter
    }

    /// Uses Claude when AI editing is on and a key is available.
    public static func makeDefault(config: VoiceFlowConfig) -> DictationPipeline {
        let key = config.effectiveAnthropicKey
        let rewriter: TextRewriter? = (config.aiCleanupEnabled && !key.isEmpty)
            ? ClaudeRewriter(apiKey: key, model: config.claudeModel, effort: config.claudeEffort)
            : nil
        return DictationPipeline(config: config, rewriter: rewriter)
    }

    public func run(transcript: String, context: DictationContext) async throws -> PipelineOutput {
        let raw = transcript.trimmed
        guard !raw.isEmpty else { throw PipelineError.emptyTranscript }
        let corrected = Personalization.applyReplacements(raw, config.replacements)

        switch context.mode {
        case .command:
            guard let rewriter else { throw PipelineError.commandNeedsAI }
            let user = PromptBuilder.commandUserMessage(
                instruction: corrected, context: context,
                vocabulary: config.vocabulary, customInstructions: config.customInstructions)
            let result = try await rewriter.rewrite(system: PromptBuilder.commandSystemPrompt, user: user)
            guard !result.trimmed.isEmpty else { throw PipelineError.emptyTranscript }
            // With a selection, the paste replaces it exactly; otherwise join the surrounding text.
            let text = context.selectedText == nil
                ? Spacing.join(preceding: context.precedingText, inserted: result)
                : result
            return PipelineOutput(text: text, aiUsed: true, warning: nil)

        case .dictation:
            let (tokenized, snippetMap) = Personalization.insertSnippetPlaceholders(corrected, config.snippets)
            var text: String
            var aiUsed = false
            var warning: String?
            if let rewriter {
                do {
                    let user = PromptBuilder.dictationUserMessage(
                        transcript: tokenized, context: context, style: config.style(for: context.category),
                        vocabulary: config.vocabulary, customInstructions: config.customInstructions)
                    text = try await rewriter.rewrite(system: PromptBuilder.dictationSystemPrompt, user: user)
                    aiUsed = true
                } catch {
                    text = LocalCleanup.clean(tokenized)
                    warning = "AI editing failed (\(error.localizedDescription)). Inserted with basic cleanup."
                }
            } else {
                text = LocalCleanup.clean(tokenized)
            }
            text = Personalization.expandPlaceholders(text, snippetMap).trimmed
            guard !text.isEmpty else { throw PipelineError.emptyTranscript }
            return PipelineOutput(
                text: Spacing.join(preceding: context.precedingText, inserted: text),
                aiUsed: aiUsed, warning: warning)
        }
    }
}
