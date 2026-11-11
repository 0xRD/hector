import Foundation

/// How many lines of one kind may go to the log per window of time.
///
/// Any administrator process can make the helper log a line by sending a request that fails. A
/// budget keeps such a client from filling the log, and from pushing what happened earlier out
/// of it when the log is cut to size.
public struct LogBudget: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var windowStart = Date.distantPast
    private var used = 0
    private var dropped = 0

    public init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    /// Whether one more line may be written at `now`, and how many were dropped in the window
    /// that just ended (to say so once, in the first line of the next one).
    public mutating func take(at now: Date = Date()) -> (allowed: Bool, droppedBefore: Int) {
        var droppedBefore = 0
        if now.timeIntervalSince(windowStart) >= window || now < windowStart {
            droppedBefore = dropped
            windowStart = now
            used = 0
            dropped = 0
        }
        guard used < limit else {
            dropped += 1
            return (false, 0)
        }
        used += 1
        return (true, droppedBefore)
    }
}
