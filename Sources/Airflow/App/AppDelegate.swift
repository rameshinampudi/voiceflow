import AirflowCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private var history: HistoryStore!
    private var controller: AppController!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private let ui = UIState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        settings = SettingsStore()
        history = HistoryStore(fileURL: ConfigStore.defaultDirectory.appendingPathComponent("history.json"))
        controller = AppController(settings: settings, history: history)

        let actions = SettingsActions(
            requestMicrophone: { [weak self] in
                if Permissions.microphoneStatus == .notDetermined {
                    Task { _ = await Permissions.requestMicrophone(); self?.ui.refreshPermissions() }
                } else {
                    Permissions.openMicrophoneSettings()
                }
            },
            requestAccessibility: {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            },
            reprepareEngine: { [weak self] in self?.controller.reprepareEngine() })

        settingsWindow = SettingsWindowController(store: settings, history: history, ui: ui, actions: actions)
        statusItem = StatusItemController(controller: controller) { [weak self] tab in
            self?.settingsWindow.show(tab: tab)
        }

        controller.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.statusItem.update(status)
            self.ui.status = status
            self.ui.engineStatus = self.controller.transcription.appleState.summary
        }
        settings.onChange = { [weak self] old, new in
            self?.controller.settingsChanged(old: old, new: new)
            if old.launchAtLogin != new.launchAtLogin { self?.applyLoginItem(new.launchAtLogin) }
        }
        controller.start()
        // Re-assert every launch, so it stays registered across updates and reinstalls.
        applyLoginItem(settings.config.launchAtLogin)

        // First run (or a permission was revoked): walk the user through it. The system
        // Accessibility prompt registers *this* signed build in System Settings, so the
        // switch the user turns on is the one macOS actually checks.
        if !Permissions.accessibilityTrusted {
            Log.app.notice("Accessibility not granted; showing the system prompt")
            Permissions.requestAccessibility()
        }
        if !Permissions.accessibilityTrusted || Permissions.microphoneStatus != .authorized {
            settingsWindow.show(tab: .general)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        settings?.saveNow()
    }

    private func applyLoginItem(_ enabled: Bool) {
        let result = LoginItem.apply(enabled)
        ui.loginItemNote = result.note
        ui.loginItemNeedsApproval = result.needsApproval
    }

    @objc private func openSettingsFromMenu() {
        settingsWindow.show(tab: .general)
    }

    /// An Edit menu, so ⌘C/⌘V/⌘A work in Settings text fields (needed to paste API keys).
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Airflow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: SettingsStore
    private let history: HistoryStore
    private let ui: UIState
    private let actions: SettingsActions

    init(store: SettingsStore, history: HistoryStore, ui: UIState, actions: SettingsActions) {
        self.store = store
        self.history = history
        self.ui = ui
        self.actions = actions
    }

    func show(tab: SettingsTab) {
        ui.tab = tab
        ui.refreshPermissions()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Airflow"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SettingsView(store: store, history: history, ui: ui, actions: actions))
            window.center()
            window.delegate = self
            self.window = window
        }
        // Show in the Dock / ⌘-Tab while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        store.saveNow()
        NSApp.setActivationPolicy(.accessory)
    }
}
