import AppKit
import Foundation
import HectorCore
import Observation

/// The security checkup: runs the read-only checks off the main thread and keeps the last report.
@MainActor
@Observable
final class CheckupController {
    private(set) var report: CheckupReport?
    private(set) var isRunning = false

    init() {
        #if DEBUG
        if DemoData.isEnabled { report = DemoData.checkupReport }
        #endif
    }

    func run() async {
        #if DEBUG
        if DemoData.isEnabled { return }
        #endif
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        // The checks run system tools and wait for them: keep that off the main actor.
        let report = await Task.detached(priority: .userInitiated) {
            SecurityCheckup().run()
        }.value
        self.report = report
    }

    /// Opens a System Settings pane. Only `x-apple.systempreferences:` links are opened, so a
    /// result can never make the app open anything else.
    func openSettings(_ url: URL) {
        guard SettingsPane.isSettingsLink(url) else { return }
        _ = NSWorkspace.shared.open(url)
    }
}
