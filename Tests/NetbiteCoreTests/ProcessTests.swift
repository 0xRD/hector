import Darwin
import Foundation
import SQLite3
import Testing
@testable import NetbiteCore

@Suite struct ProcessCollectorTests {
    /// Builds a KERN_PROCARGS2 buffer the way the kernel lays it out.
    private func procArgs(argc: Int32, executable: String, padding: Int, arguments: [String], environment: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(executable.utf8) + [0]
        bytes += [UInt8](repeating: 0, count: padding)
        for string in arguments + environment { bytes += Array(string.utf8) + [0] }
        return bytes
    }

    @Test func parsesArgumentsAndIgnoresTheEnvironment() throws {
        let buffer = procArgs(argc: 3, executable: "/usr/bin/python3", padding: 5,
                              arguments: ["python3", "-c", "print('hi there')"], environment: ["API_TOKEN=secret"])
        let parsed = try #require(ProcessCollector.parseProcArgs2(buffer))
        #expect(parsed.executable == "/usr/bin/python3")
        #expect(parsed.arguments == ["python3", "-c", "print('hi there')"])
    }

    @Test func toleratesTruncatedOrBrokenBuffers() {
        #expect(ProcessCollector.parseProcArgs2([UInt8]()) == nil)
        #expect(ProcessCollector.parseProcArgs2([1, 0]) == nil)
        // argc says 4 but only one argument is there: keep what was read.
        let short = procArgs(argc: 4, executable: "/bin/sh", padding: 0, arguments: ["sh"], environment: [])
        #expect(ProcessCollector.parseProcArgs2(short)?.arguments == ["sh"])
        // Negative argc.
        #expect(ProcessCollector.parseProcArgs2(procArgs(argc: -1, executable: "/x", padding: 0, arguments: [], environment: [])) == nil)
        // No terminating NUL after the path.
        var unterminated = withUnsafeBytes(of: Int32(1)) { Array($0) }
        unterminated += Array("/bin/sh".utf8)
        #expect(ProcessCollector.parseProcArgs2(unterminated) == nil)
    }

    @Test func listsTheTestRunnerItself() throws {
        let snapshot = ProcessCollector().snapshot()
        let me = try #require(snapshot.processes.first { $0.pid == getpid() })
        #expect(me.parentPID == getppid())
        #expect(me.userID == getuid())
        #expect(me.executablePath != nil)
        #expect(!me.arguments.isEmpty)
        #expect(me.startedAt != nil)
        #expect(me.connections != nil)
        #expect(snapshot.processes.contains { $0.pid == 1 })
        #expect(snapshot.processes.map(\.pid) == snapshot.processes.map(\.pid).sorted())
    }

    @Test func flagsSuspiciousLocations() {
        let present: (String) -> Bool = { _ in true }
        #expect(ProcessFlag.flags(forExecutable: "/Applications/Safari.app/Contents/MacOS/Safari", exists: present).isEmpty)
        #expect(ProcessFlag.flags(forExecutable: "/private/var/folders/xy/abc/T/payload", exists: present) == [.temporaryFolder])
        #expect(ProcessFlag.flags(forExecutable: "/tmp/run", exists: present) == [.temporaryFolder])
        #expect(ProcessFlag.flags(forExecutable: "/Users/alex/Downloads/Tool.app/Contents/MacOS/Tool", exists: present) == [.downloads])
        #expect(ProcessFlag.flags(forExecutable: "/Users/alex/.local/bin/agent", exists: present) == [.hiddenPath])
        #expect(ProcessFlag.flags(forExecutable: "/Users/alex/Library/.hidden", exists: present) == [.hiddenPath])
        #expect(ProcessFlag.flags(forExecutable: "/usr/local/bin/gone", exists: { _ in false }) == [.deletedExecutable])
        // A folder merely named Downloads elsewhere is not a user's Downloads folder.
        #expect(ProcessFlag.flags(forExecutable: "/opt/Downloads/tool", exists: present).isEmpty)
        #expect(ProcessFlag.flags(forExecutable: nil).isEmpty)
        #expect(ProcessFlag.flags(forExecutable: "relative/path", exists: present).isEmpty)
    }
}

@Suite struct QuarantineTests {
    @Test func parsesTheAttribute() throws {
        let info = try #require(Quarantine.parseAttribute("0083;5f1c2a3b;Safari;8F1C5B0E-1D2C-4C7E-9B9B-0A1B2C3D4E5F\n"))
        #expect(info.flags == 0x83)
        #expect(info.downloadedAt == Date(timeIntervalSince1970: 0x5f1c2a3b))
        #expect(info.agent == "Safari")
        #expect(info.eventID == "8F1C5B0E-1D2C-4C7E-9B9B-0A1B2C3D4E5F")
        #expect(!info.userApproved)
        #expect(Quarantine.parseAttribute("00c1;5f1c2a3b;;")?.userApproved == true)
    }

    @Test func refusesGarbage() {
        #expect(Quarantine.parseAttribute("") == nil)
        #expect(Quarantine.parseAttribute("not hex;1;x;y") == nil)
        // An identifier that is not a UUID is never kept, so it is never looked up.
        #expect(Quarantine.parseAttribute("0083;5f1c2a3b;Safari;' OR 1=1 --")?.eventID == nil)
    }

    @Test func readsTheDownloadURLFromTheEventsDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "netbite-quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appending(path: "QuarantineEventsV2")
        let id = "8F1C5B0E-1D2C-4C7E-9B9B-0A1B2C3D4E5F"

        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        let setup = """
        CREATE TABLE LSQuarantineEvent (LSQuarantineEventIdentifier TEXT PRIMARY KEY NOT NULL,
          LSQuarantineTimeStamp REAL, LSQuarantineAgentBundleIdentifier TEXT, LSQuarantineAgentName TEXT,
          LSQuarantineDataURLString TEXT, LSQuarantineSenderName TEXT, LSQuarantineSenderAddress TEXT,
          LSQuarantineTypeNumber INTEGER, LSQuarantineOriginTitle TEXT, LSQuarantineOriginURLString TEXT,
          LSQuarantineOriginAlias BLOB);
        INSERT INTO LSQuarantineEvent (LSQuarantineEventIdentifier, LSQuarantineDataURLString, LSQuarantineOriginURLString)
          VALUES ('\(id)', 'https://downloads.example.com/Tool.dmg', 'https://example.com/tool');
        """
        #expect(sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let event = try #require(Quarantine.lookupEvent(id.lowercased(), in: database))
        #expect(event.dataURL == "https://downloads.example.com/Tool.dmg")
        #expect(event.originURL == "https://example.com/tool")
        #expect(Quarantine.lookupEvent("00000000-0000-0000-0000-000000000000", in: database) == nil)
        #expect(Quarantine.lookupEvent(id, in: folder.appending(path: "missing")) == nil)
    }

    @Test func readsTheAttributeOfAFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "netbite-quarantined-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(Quarantine.info(forFileAt: file.path, database: nil) == nil)

        let value = Array("0081;5f1c2a3b;Firefox;".utf8)
        #expect(setxattr(file.path, "com.apple.quarantine", value, value.count, 0, 0) == 0)
        let info = try #require(Quarantine.info(forFileAt: file.path, database: nil))
        #expect(info.agent == "Firefox")
        #expect(info.eventID == nil)
    }
}
