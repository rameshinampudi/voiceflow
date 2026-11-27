import Foundation

/// Offline cleanup used when AI editing is off, has no key, or fails.
public enum LocalCleanup {
    // um, umm, uh, uhh, uhm, erm, hmm — not "ah"/"er"/"like", which are often real words.
    private static let filler = try! NSRegularExpression(
        pattern: #"[ \t]*,?[ \t]*\b(?:u+m+|u+h+m*|e+r+m+|h+m+)\b[ \t]*,?"#,
        options: [.caseInsensitive])
    // "ah," / "er," set off by a comma are hesitations; "Ah" on its own may be meant.
    private static let commaFiller = try! NSRegularExpression(
        pattern: #"[ \t]*,?[ \t]*\b(?:a+h+|e+r+)\b,"#, options: [.caseInsensitive])
    private static let newParagraph = try! NSRegularExpression(
        pattern: #"[ \t]*,?[ \t]*\bnew paragraph\b[.,!?]?[ \t]*"#, options: [.caseInsensitive])
    private static let newLine = try! NSRegularExpression(
        pattern: #"[ \t]*,?[ \t]*\bnew line\b[.,!?]?[ \t]*"#, options: [.caseInsensitive])

    public static func clean(_ text: String) -> String {
        var s = removeFillers(text)
        s = applyVoiceCommands(s)
        s = normalizePunctuationSpacing(s)
        s = capitalizeSentenceStarts(s.trimmed)
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return s
    }

    public static func removeFillers(_ text: String) -> String {
        replace(commaFiller, in: replace(filler, in: text, with: " "), with: " ")
    }

    public static func applyVoiceCommands(_ text: String) -> String {
        replace(newLine, in: replace(newParagraph, in: text, with: "\n\n"), with: "\n")
    }

    public static func normalizePunctuationSpacing(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #",{2,}"#, with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: #",([.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^[ \t,]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)[ \t]+$"#, with: "", options: .regularExpression)
        return s
    }

    /// Capitalizes the first letter of the text and of each line.
    public static func capitalizeSentenceStarts(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in text {
            if ch == "\n" {
                capitalizeNext = true
                out.append(ch)
                continue
            }
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: ch.uppercased())
                capitalizeNext = false
                continue
            }
            if ch.isLetter || ch.isNumber { capitalizeNext = false }
            out.append(ch)
        }
        return out
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Personal dictionary replacements and snippets.
public enum Personalization {
    static func phrasePattern(_ phrase: String) -> String {
        let words = phrase.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        return #"(?<![\p{L}\p{N}_])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}_])"#
    }

    public static func applyReplacements(_ text: String, _ replacements: [Replacement]) -> String {
        var s = text
        for r in replacements {
            let heard = r.heard.trimmed
            guard !heard.isEmpty,
                  let regex = try? NSRegularExpression(pattern: phrasePattern(heard), options: .caseInsensitive)
            else { continue }
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s),
                withTemplate: NSRegularExpression.escapedTemplate(for: r.written))
        }
        return s
    }

    public static func placeholder(_ index: Int) -> String { "⟦S\(index)⟧" }

    /// Swaps spoken snippet triggers for placeholder tokens the AI editor leaves alone,
    /// so expansions (links, addresses, boilerplate) come out byte-exact.
    public static func insertSnippetPlaceholders(_ text: String, _ snippets: [Snippet]) -> (String, [String: String]) {
        var s = text
        var map: [String: String] = [:]
        // Longest trigger first, so "my work email" wins over "my email".
        let usable = snippets
            .filter { !$0.trigger.trimmed.isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
        for (i, snippet) in usable.enumerated() {
            let token = placeholder(i + 1)
            // Also swallow the recognizer's sentence-final period after a trigger at the very end.
            let pattern = phrasePattern(snippet.trigger) + #"(?:[.!?](?=\s*$))?"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            guard regex.firstMatch(in: s, range: range) != nil else { continue }
            s = regex.stringByReplacingMatches(
                in: s, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: token))
            map[token] = snippet.expansion
        }
        return (s, map)
    }

    public static func expandPlaceholders(_ text: String, _ map: [String: String]) -> String {
        var s = text
        for (token, expansion) in map {
            s = s.replacingOccurrences(of: token, with: expansion)
        }
        return s
    }
}

/// Decides whether inserted text needs a leading space, given what's before the cursor.
public enum Spacing {
    static let noSpaceBefore: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "…", "%"]
    static let noSpaceAfter: Set<Character> = ["(", "[", "{", "/", "@", "#", "$"]

    public static func join(preceding: String?, inserted: String) -> String {
        guard let first = inserted.first, let last = preceding?.last else { return inserted }
        if last.isWhitespace || first.isWhitespace { return inserted }
        if noSpaceBefore.contains(first) || noSpaceAfter.contains(last) { return inserted }
        return " " + inserted
    }
}
