import AppKit

// `VoiceFlow --selftest`, `--transcribe <file>`, `--cleanup "<text>"`: headless checks, no UI.
if CLI.handles(CommandLine.arguments) {
    CLI.run(CommandLine.arguments)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu-bar app, no Dock icon
    withExtendedLifetime(delegate) {
        app.run()
    }
}
