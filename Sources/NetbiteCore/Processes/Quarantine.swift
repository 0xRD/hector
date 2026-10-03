import Darwin
import Foundation
import SQLite3

/// Where a downloaded file came from, as Gatekeeper recorded it.
///
/// macOS tags downloads with the `com.apple.quarantine` extended attribute (flags, date, the app
/// that downloaded the file, and an event identifier); the identifier points to a row in the
/// user's quarantine events database, which holds the download URL.
public struct QuarantineInfo: Codable, Hashable, Sendable {
    public var flags: UInt32
    public var downloadedAt: Date?
    /// The app that downloaded the file ("Safari", "Google Chrome"…), when recorded.
    public var agent: String?
    public var eventID: String?
    /// Filled from the quarantine events database when the event is found there.
    public var dataURL: String?
    public var originURL: String?

    public init(flags: UInt32, downloadedAt: Date? = nil, agent: String? = nil, eventID: String? = nil,
                dataURL: String? = nil, originURL: String? = nil) {
        self.flags = flags
        self.downloadedAt = downloadedAt
        self.agent = agent
        self.eventID = eventID
        self.dataURL = dataURL
        self.originURL = originURL
    }

    /// The user opened the file and accepted the Gatekeeper prompt (bit 0x40).
    public var userApproved: Bool { flags & 0x40 != 0 }
}

public enum Quarantine {
    static let attributeName = "com.apple.quarantine"

    /// The default quarantine events database of the current user.
    public static var eventsDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
    }

    /// The quarantine record of the file at `path`, completed from `database` when possible.
    /// `nil` when the file carries no quarantine attribute.
    public static func info(forFileAt path: String, database: URL? = eventsDatabase) -> QuarantineInfo? {
        guard let raw = attribute(atPath: path), var info = parseAttribute(raw) else { return nil }
        if let id = info.eventID, let database, let event = lookupEvent(id, in: database) {
            info.dataURL = event.dataURL
            info.originURL = event.originURL
        }
        return info
    }

    /// The quarantine record of a process's code: the app bundle when there is one (that is what
    /// the browser tagged), else the executable itself.
    public static func info(for process: RunningProcess, database: URL? = eventsDatabase) -> QuarantineInfo? {
        for path in [process.appBundlePath, process.executablePath].compactMap({ $0 }) {
            if let info = info(forFileAt: path, database: database) { return info }
        }
        return nil
    }

    static func attribute(atPath path: String) -> String? {
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0, size < 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attributeName, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }

    /// Parses `0083;5f1c2a3b;Safari;8F1C5B0E-…`: hexadecimal flags, hexadecimal Unix time, agent,
    /// event identifier. Missing trailing fields are allowed.
    static func parseAttribute(_ raw: String) -> QuarantineInfo? {
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let first = fields.first, let flags = UInt32(first, radix: 16) else { return nil }
        var info = QuarantineInfo(flags: flags)
        if fields.count > 1, let seconds = UInt64(fields[1], radix: 16), seconds > 0 {
            info.downloadedAt = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        if fields.count > 2, !fields[2].isEmpty { info.agent = fields[2] }
        if fields.count > 3, isEventID(fields[3]) { info.eventID = fields[3] }
        return info
    }

    /// A UUID, the only shape of identifier that is ever looked up.
    static func isEventID(_ string: String) -> Bool {
        UUID(uuidString: string) != nil
    }

    /// Reads one event from the quarantine database, opened read-only. The identifier is bound as a
    /// parameter, never put into the SQL text.
    static func lookupEvent(_ id: String, in database: URL) -> (dataURL: String?, originURL: String?)? {
        guard isEventID(id) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        let sql = """
        SELECT LSQuarantineDataURLString, LSQuarantineOriginURLString
        FROM LSQuarantineEvent WHERE LSQuarantineEventIdentifier = ? COLLATE NOCASE LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: SQLite copies the string before this call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }

        func column(_ index: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, index) else { return nil }
            let string = String(cString: text)
            return string.isEmpty ? nil : string
        }
        return (column(0), column(1))
    }
}
