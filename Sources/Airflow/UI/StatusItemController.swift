import AppKit

/// The menu-bar icon and its menu.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let handsFreeItem = NSMenuItem(title: "Start Hands-free Dictation", action: nil, keyEquivalent: "")
    private let controller: AppController
    private let openSettings: (SettingsTab) -> Void

    init(controller: AppController, openSettings: @escaping (SettingsTab) -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        super.init()
        build()
    }

    func update(_ status: AppStatus) {
        statusLine.title = status.menuTitle
        setIcon(status.symbol)
        handsFreeItem.title = controller.isHandsFree ? "Finish Hands-free Dictation" : "Start Hands-free Dictation"
    }

    private func build() {
        setIcon("wind")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        let hint = NSMenuItem(title: "Hold ⌥ to talk · double-tap for hands-free", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        handsFreeItem.action = #selector(toggleHandsFree)
        handsFreeItem.target = self
        menu.addItem(handsFreeItem)
        menu.addItem(item("Paste Last Dictation (⌃⌘V)", #selector(pasteLast)))
        menu.addItem(.separator())
        menu.addItem(item("History…", #selector(showHistory)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Airflow", #selector(quit), key: "q"))
        self.item.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Airflow")
        image?.isTemplate = true
        item.button?.image = image
    }

    @objc private func toggleHandsFree() { controller.toggleHandsFree() }
    @objc private func pasteLast() {
        // Give the menu time to close so focus returns to the previous app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [controller] in
            controller.pasteLastFromMenu()
        }
    }
    @objc private func showHistory() { openSettings(.history) }
    @objc private func showSettings() { openSettings(.general) }
    @objc private func quit() { NSApp.terminate(nil) }
}
