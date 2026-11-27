import AVFoundation
import VoiceFlowCore
import Foundation

/// Live settings, saved to disk shortly after each change.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var config: VoiceFlowConfig {
        didSet {
            guard config != oldValue else { return }
            onChange?(oldValue, config)
            scheduleSave()
        }
    }
    var onChange: ((VoiceFlowConfig, VoiceFlowConfig) -> Void)?

    private let store: ConfigStore
    private var saveWork: DispatchWorkItem?

    var configPath: String { store.fileURL.path }

    init(store: ConfigStore = ConfigStore()) {
        self.store = store
        self.config = store.load()
    }

    func saveNow() {
        saveWork?.cancel()
        do {
            try store.save(config)
        } catch {
            NSLog("VoiceFlow: could not save settings: \(error)")
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

enum SettingsTab: String, Hashable {
    case general, transcription, ai, dictionary, history
}

/// State the Settings window shows that doesn't live in the config file.
@MainActor
final class UIState: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var accessibilityGranted = Permissions.accessibilityTrusted
    @Published var microphoneStatus = Permissions.microphoneStatus
    @Published var engineStatus = "Not prepared yet"
    @Published var status: AppStatus = .ready
    @Published var loginItemNote: String?
    @Published var loginItemNeedsApproval = false

    func refreshPermissions() {
        let ax = Permissions.accessibilityTrusted
        if ax != accessibilityGranted { accessibilityGranted = ax }
        let mic = Permissions.microphoneStatus
        if mic != microphoneStatus { microphoneStatus = mic }
    }
}
