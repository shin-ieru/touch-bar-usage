import Foundation
import ServiceManagement
import TouchBarUsageKit

/// Launch-at-login via `SMAppService`. Requires macOS 13, which is our
/// deployment target, and needs no helper bundle or extra entitlement.
enum LoginItemService {
    private static let log = Log(category: "loginitem")

    static var isAvailable: Bool { true }   // guaranteed by the macOS 13 target

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns whether the requested state was reached. `SMAppService` throws
    /// when the app is not in a location the system will register (for example
    /// a raw binary run from `.build`), which is expected during development.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            log.info("login item updated", ["enabled": "\(enabled)"])
            return true
        } catch {
            log.warning("login item update failed", ["enabled": "\(enabled)"])
            return false
        }
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:        return "enabled"
        case .notRegistered:  return "not registered"
        case .requiresApproval: return "requires approval in System Settings"
        case .notFound:       return "not found"
        @unknown default:     return "unknown"
        }
    }
}
