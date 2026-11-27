import Foundation

/// Maps the frontmost app (and, for browsers, the tab title) to a writing category.
public enum AppClassifier {
    static let email: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron",
        "com.readdle.SparkDesktop", "com.readdle.smartemail-Mac", "com.mimestream.Mimestream",
        "it.bloop.airmail2", "com.freron.MailMate", "org.mozilla.thunderbird",
    ]
    static let workMessages: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos",
    ]
    static let personalMessages: Set<String> = [
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram",
        "org.telegram.desktop", "org.whispersystems.signal-desktop", "com.hnc.Discord",
        "com.facebook.archon", "com.facebook.Messenger",
    ]
    static let code: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "dev.zed.Zed", "com.sublimetext.4", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "com.panic.Nova",
    ]
    static let codePrefixes = ["com.jetbrains.", "com.google.android.studio"]
    static let aiApps: Set<String> = ["com.openai.chat", "com.anthropic.claudefordesktop"]
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "company.thebrowser.dia", "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
    ]

    public static func category(bundleID: String?, windowTitle: String?) -> AppCategory {
        let id = bundleID ?? ""
        if email.contains(id) { return .email }
        if workMessages.contains(id) { return .workMessages }
        if personalMessages.contains(id) { return .personalMessages }
        if code.contains(id) || codePrefixes.contains(where: { id.hasPrefix($0) }) { return .code }
        if aiApps.contains(id) { return .aiPrompt }
        if browsers.contains(id), let title = windowTitle {
            return category(forBrowserTitle: title) ?? .other
        }
        return .other
    }

    static func category(forBrowserTitle title: String) -> AppCategory? {
        let t = title.lowercased()
        let rules: [(AppCategory, [String])] = [
            (.email, ["gmail", "outlook", "inbox", "proton mail", "fastmail", "superhuman", "yahoo mail"]),
            (.workMessages, ["slack", "microsoft teams", "google chat"]),
            (.personalMessages, ["whatsapp", "messenger", "telegram", "discord", "instagram"]),
            (.aiPrompt, ["chatgpt", "claude", "gemini", "perplexity"]),
        ]
        for (category, needles) in rules where needles.contains(where: { t.contains($0) }) {
            return category
        }
        return nil
    }
}
