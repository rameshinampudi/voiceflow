import AirflowCore
import AppKit

/// The menu-bar icon and its menu, including a Recent Dictations list you can copy from.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let handsFreeItem = NSMenuItem(title: "Start Hands-free Dictation", action: nil, keyEquivalent: "")
    private let recentMenu = NSMenu(title: "Recent Dictations")
    private let controller: AppController
    private let openSettings: (SettingsTab) -> Void
    private let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let recentCount = 12

    init(controller: AppController, openSettings: @escaping (SettingsTab) -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        super.init()
        build()
    }

    func update(_ status: AppStatus) {
        statusLine.title = status.menuTitle
        setIcon(status == .ready ? nil : status.symbol)
        handsFreeItem.title = controller.isHandsFree ? "Finish Hands-free Dictation" : "Start Hands-free Dictation"
    }

    private func build() {
        setIcon(nil)
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

        let recentItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(.separator())

        menu.addItem(item("History…", #selector(showHistory), key: "y"))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Airflow", #selector(quit), key: "q"))
        self.item.menu = menu
    }

    // MARK: - Recent dictations

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let recent = controller.history.search("", limit: Self.recentCount)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet — hold ⌥ and talk", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Click to copy, then ⌘V anywhere", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in recent {
                let menuItem = NSMenuItem(title: Self.preview(entry.finalText), action: #selector(copyRecent(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = entry.finalText
                menuItem.subtitle = [entry.appName, relativeTime.localizedString(for: entry.date, relativeTo: Date())]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                menuItem.toolTip = entry.finalText
                menu.addItem(menuItem)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Show All History…", #selector(showHistory)))
    }

    static func preview(_ text: String, limit: Int = 60) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmed
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        controller.copyToClipboard(text)
    }

    // MARK: - Helpers

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    /// nil = the Airflow brand glyph (mic turning into text); otherwise an SF Symbol for the state.
    private func setIcon(_ symbol: String?) {
        let image: NSImage?
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Airflow")
        } else {
            image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Airflow")
        }
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
