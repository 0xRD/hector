import Darwin
import Foundation
import HectorCore

/// The helper's log: standard error, which launchd appends to /Library/Logs/Hector/hectord.log.
///
/// Nothing else trims that file, so the helper does: when it reaches `maximumSize` it is copied
/// to `hectord.log.1` (replacing the previous copy) and emptied. The two files together never
/// hold more than twice that size. Lines a client can cause at will go through a budget
/// (`failure`), so a client cannot fill the log or push its history out in a few seconds.
enum HelperLog {
    static let maximumSize = 4 << 20
    /// The size is looked at again after this many bytes were written.
    static let checkEvery = 64 << 10
    /// Failed requests logged per minute; at 500 characters each, hours to turn the log over.
    static let failuresPerMinute = 30
    static let maximumFailureLength = 500

    /// The file launchd writes standard error to; a dry run sets its own.
    nonisolated(unsafe) static var path = HelperPaths.logFile

    private static let lock = NSLock()
    /// Starts at the threshold: the first line of a launch checks the size.
    nonisolated(unsafe) private static var writtenSinceCheck = checkEvery
    nonisolated(unsafe) private static var failures = LogBudget(limit: failuresPerMinute, window: 60)

    /// Every line goes through `LogText.sanitized`: messages can carry text sent by a client.
    static func write(_ message: String) {
        lock.withLock { writeLocked(message) }
    }

    /// A line any client can cause: cut short, and at most `failuresPerMinute` a minute.
    static func failure(_ message: String) {
        lock.withLock {
            let (allowed, dropped) = failures.take()
            guard allowed else { return }
            if dropped > 0 { writeLocked("\(dropped) more failed requests were not logged.") }
            writeLocked(String(message.prefix(maximumFailureLength)))
        }
    }

    private static func writeLocked(_ message: String) {
        let line = Data("\(Date().formatted(.iso8601)) \(LogText.sanitized(message))\n".utf8)
        FileHandle.standardError.write(line)
        writtenSinceCheck += line.count
        if writtenSinceCheck >= checkEvery {
            writtenSinceCheck = 0
            trimIfNeeded()
        }
    }

    /// Only when standard error is the log file itself (same device and inode): a terminal, a
    /// pipe or a file someone redirected a dry run to is left alone.
    private static func trimIfNeeded() {
        var output = stat()
        guard fstat(STDERR_FILENO, &output) == 0, output.st_mode & S_IFMT == S_IFREG, output.st_size >= maximumSize else { return }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_dev == output.st_dev, file.st_ino == output.st_ino else { return }
        // Keep the last copy readable next to it; if that fails the log is still emptied.
        if let contents = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximumSize * 2) {
            try? SecureFiles.write(contents, to: path + ".1", mode: 0o644)
        }
        ftruncate(STDERR_FILENO, 0)
        // launchd opens it for appending; if it did not, writing must still restart at the top.
        lseek(STDERR_FILENO, 0, SEEK_SET)
    }
}

func log(_ message: String) {
    HelperLog.write(message)
}
