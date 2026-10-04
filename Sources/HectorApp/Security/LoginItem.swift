import Foundation
import Observation
import ServiceManagement

/// "Open Hector at login", through the system's login items (`SMAppService.mainApp`). Works with
/// an ad hoc signature: macOS lists the app under General → Login Items, where the user can also
/// switch it off.
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()

    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var error: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    /// Registered, but switched off in System Settings: only the user can turn it back on there.
    var needsApproval: Bool { status == .requiresApproval }

    /// Reads the state again: it may have changed in System Settings.
    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
