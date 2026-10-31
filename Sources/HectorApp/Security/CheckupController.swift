import AppKit
import Foundation
import HectorCore
import Observation

/// The security checkup: runs the read-only checks off the main thread, keeps the last report,
/// and says which verdicts changed since the run before it (kept across launches).
@MainActor
@Observable
final class CheckupController {
    /// The verdicts of one run, as kept between launches.
    struct Snapshot: Codable {
        var checkedAt: Date
        var statuses: [String: CheckResult.Status]
    }

    private static let previousKey = "checkupPrevious"

    private(set) var report: CheckupReport?
    private(set) var isRunning = false
    /// The run the current report is compared with.
    private(set) var previous: Snapshot?

    init() {
        #if DEBUG
        if DemoData.isEnabled {
            report = DemoData.checkupReport
            previous = DemoData.previousCheckup
            return
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: Self.previousKey) {
            previous = try? JSONDecoder().decode(Snapshot.self, from: data)
        }
    }

    /// What a check was in the previous run, when its verdict changed since. Checks that are new
    /// in this version of Hector have no previous verdict and are not reported as changed.
    func previousStatus(of result: CheckResult) -> CheckResult.Status? {
        guard let before = previous?.statuses[result.id], before != result.status else { return nil }
        return before
    }

    var changedCount: Int {
        report?.results.filter { previousStatus(of: $0) != nil }.count ?? 0
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
        // The report on screen becomes the one the next run is compared with; at the first run of
        // a launch, that is the last one saved.
        if let shown = self.report {
            previous = Snapshot(checkedAt: shown.checkedAt,
                                statuses: Dictionary(uniqueKeysWithValues: shown.results.map { ($0.id, $0.status) }))
        }
        self.report = report
        let snapshot = Snapshot(checkedAt: report.checkedAt,
                                statuses: Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0.status) }))
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: Self.previousKey)
    }

    /// Opens a System Settings pane. Only `x-apple.systempreferences:` links are opened, so a
    /// result can never make the app open anything else.
    func openSettings(_ url: URL) {
        guard SettingsPane.isSettingsLink(url) else { return }
        _ = NSWorkspace.shared.open(url)
    }
}
