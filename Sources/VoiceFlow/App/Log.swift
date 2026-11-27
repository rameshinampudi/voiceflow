import os

/// Diagnostics. Read with:
///   log show --last 10m --info --predicate 'subsystem == "local.voiceflow.dictation"'
/// Never logs what you said — only lengths, states and errors.
enum Log {
    static let app = Logger(subsystem: "local.voiceflow.dictation", category: "app")
}
