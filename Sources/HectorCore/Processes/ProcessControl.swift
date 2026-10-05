import Darwin
import Foundation

/// Quitting the user's own processes from the Processes screen. Only what a normal user can do
/// anyway (`kill` on their own processes); never through the helper, never another user's process.
public enum ProcessControl {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// Another user's process (root, a system account, or someone else logged in).
        case notYours
        /// Hector itself: it would quit the window the user is looking at.
        case isHector
        /// Already gone.
        case exited
        /// The PID now belongs to another process (it exited and the number was reused).
        case replaced
        /// `kill` failed with this `errno`.
        case failed(Int32)

        public var description: String {
            switch self {
            case .notYours: "It belongs to another user."
            case .isHector: "It is Hector itself."
            case .exited: "It has already quit."
            case .replaced: "It has already quit, and its number now belongs to another process."
            case let .failed(code): String(cString: strerror(code))
            }
        }
    }

    /// Whether Quit is offered for `process`: the user's own, not Hector, with a known start time
    /// (needed to tell it from a later process that reuses the PID).
    public static func canQuit(_ process: RunningProcess, userID: uid_t = getuid(), ownPID: pid_t = getpid()) -> Bool {
        refusal(for: process, userID: userID, ownPID: ownPID) == nil
    }

    static func refusal(for process: RunningProcess, userID: uid_t, ownPID: pid_t) -> Refusal? {
        if process.pid == ownPID { return .isHector }
        guard process.pid > 1, process.userID == userID, userID != 0, process.startedAt != nil else { return .notYours }
        return nil
    }

    /// Checks that `process.pid` is still the process the user saw: same owner and start time.
    /// Throws a `Refusal` otherwise.
    public static func verify(_ process: RunningProcess, userID: uid_t = getuid(), ownPID: pid_t = getpid()) throws {
        if let refusal = refusal(for: process, userID: userID, ownPID: ownPID) { throw refusal }
        guard let now = ProcessCollector.basicInfo(of: process.pid) else { throw Refusal.exited }
        // `RunningProcess` keeps whole seconds; compare the same way.
        let started = now.startedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        guard now.userID == process.userID, started == process.startedAt else { throw Refusal.replaced }
    }

    /// Sends SIGTERM (a polite quit: the process may clean up, or ignore it) after `verify`.
    public static func terminate(_ process: RunningProcess, userID: uid_t = getuid(), ownPID: pid_t = getpid()) throws {
        try verify(process, userID: userID, ownPID: ownPID)
        if kill(process.pid, SIGTERM) != 0 {
            throw errno == ESRCH ? Refusal.exited : Refusal.failed(errno)
        }
    }
}
