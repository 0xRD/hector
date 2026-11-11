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

    /// A scan older than this is given up on, and a new one may start.
    static let abandonAfter: TimeInterval = 60
    /// Scans given up on that may still be running. Each holds one thread, so no more than this.
    static let maximumAbandoned = 3

    private let condition = NSCondition()
    /// A report is made for one reader, with or without root's text.
    private struct Reader: Hashable {
        var viewer: uid_t
        var rootText: Bool
    }

    private var reports: [Reader: (madeAt: Date, report: PrivilegedPersistence)] = [:]
    private var running: (id: Int, startedAt: Date)?
    private var lastID = 0
    private var abandoned = 0

    func report(for viewer: uid_t, rootText: Bool) throws -> PrivilegedPersistence {
        let reader = Reader(viewer: viewer, rootText: rootText)
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Self.patience)
        var started = false
        while true {
            if let cached = reports[reader], Date().timeIntervalSince(cached.madeAt) < Self.freshness { return cached.report }
            if let scan = running {
                let age = Date().timeIntervalSince(scan.startedAt)
                if age >= Self.abandonAfter, abandoned < Self.maximumAbandoned {
                    // Hung for good (a home folder on a dead volume): it must not stop every
                    // later scan, and a few such threads at most are left behind.
                    abandoned += 1
                    running = nil
                    log("warning: a scan of root-only persistence locations has not ended after \(Int(age)) s; starting another.")
                    continue
                }
                // Not behind a scan that already outlived a client's patience.
                guard age < Self.patience, condition.wait(until: deadline) else {
                    throw HelperError("The scan of root-only persistence locations is taking too long; try again later.")
                }
                continue
            }
            // The scan this call started ended and its report is gone: only if the clock jumped.
            guard !started else { throw HelperError("The scan of root-only persistence locations failed.") }
            started = true
            lastID += 1
            let id = lastID
            running = (id, Date())
            let root = Self.systemRoot
            // Its own thread: the client's thread must be free to give up.
            Thread.detachNewThread { [self] in
                let report = PrivilegedPersistenceScanner(system: root).scan(viewer: viewer, includesRootText: rootText)
                condition.lock()
                let now = Date()
                reports = reports.filter { now.timeIntervalSince($0.value.madeAt) < Self.freshness }
                reports[reader] = (now, report)
                if running?.id == id { running = nil } else { abandoned -= 1 }
                condition.broadcast()
                condition.unlock()
            }
        }
    }
}
