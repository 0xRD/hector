import Darwin
import Foundation
import HectorCore

/// Serves `rootPersistence`: at most one scan at a time, and a recent answer is given again.
///
/// The request takes no input, but any administrator process may send it as often as it likes.
/// Without this a client could keep root walking every home folder on eight threads; with it,
/// repeated requests cost one scan every few seconds whatever their number. A scan that hangs
/// (a home folder on a dead network volume) is abandoned by its client after `patience`, and no
/// new one starts behind it.
final class PrivilegedScans: @unchecked Sendable {
    static let shared = PrivilegedScans()

    /// A report is given again for this long.
    static let freshness: TimeInterval = 5
    /// How long a client waits for a scan.
    static let patience: TimeInterval = 20

    /// Set once by `serve`, before the first connection: `/`, or the folder of a dry run.
    nonisolated(unsafe) static var systemRoot = "/"

    private let condition = NSCondition()
    private var reports: [uid_t: (madeAt: Date, report: PrivilegedPersistence)] = [:]
    private var scanStartedAt: Date?

    func report(for viewer: uid_t) throws -> PrivilegedPersistence {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Self.patience)
        var started = false
        while true {
            if let cached = reports[viewer], Date().timeIntervalSince(cached.madeAt) < Self.freshness { return cached.report }
            if let scanStartedAt {
                // Not behind a scan that already outlived a client's patience.
                guard Date().timeIntervalSince(scanStartedAt) < Self.patience, condition.wait(until: deadline) else {
                    throw HelperError("The scan of root-only persistence locations is taking too long; try again later.")
                }
                continue
            }
            // The scan this call started ended and its report is gone: only if the clock jumped.
            guard !started else { throw HelperError("The scan of root-only persistence locations failed.") }
            started = true
            scanStartedAt = Date()
            let root = Self.systemRoot
            // Its own thread: the client's thread must be free to give up.
            Thread.detachNewThread { [self] in
                let report = PrivilegedPersistenceScanner(system: root).scan(viewer: viewer)
                condition.lock()
                let now = Date()
                reports = reports.filter { now.timeIntervalSince($0.value.madeAt) < Self.freshness }
                reports[viewer] = (now, report)
                scanStartedAt = nil
                condition.broadcast()
                condition.unlock()
            }
        }
    }
}
