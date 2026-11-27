import Foundation
import ServiceManagement

/// "Open at Login" via SMAppService — shows up in System Settings → General → Login Items,
/// and starts Airflow every time you log in, including after a restart.
enum LoginItem {
    struct Result {
        var note: String?
        var needsApproval: Bool
    }

    /// Only the installed copy registers, so a test build in build/ never hijacks the login item.
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    @discardableResult
    static func apply(_ enabled: Bool) -> Result {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard isInstalledCopy else {
                    return Result(note: "Install Airflow with `make install` so it can start at login.", needsApproval: false)
                }
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            Log.app.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            return Result(
                note: "Couldn't update the login item: \(error.localizedDescription)",
                needsApproval: service.status == .requiresApproval)
        }
        Log.app.notice("Login item status: \(statusName(service.status), privacy: .public)")
        return describe(service.status, enabled: enabled)
    }

    static func describe(_ status: SMAppService.Status, enabled: Bool) -> Result {
        switch status {
        case .enabled:
            return Result(note: "Airflow starts automatically when you log in, including after a restart.", needsApproval: false)
        case .requiresApproval:
            return Result(note: "macOS needs your OK: allow Airflow in System Settings → General → Login Items.", needsApproval: true)
        default:
            return Result(note: nil, needsApproval: false)
        }
    }

    static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
