import Darwin
import Foundation
import SQLite3
import Testing
@testable import HectorCore

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

    @Test func ordersTheTreeDepthFirst() {
        func process(_ pid: Int32, _ parent: Int32) -> RunningProcess {
            RunningProcess(pid: pid, parentPID: parent, userID: 501, name: "p\(pid)")
        }
        // 1 → (5 → 9), 3; 7's parent is gone; 11 and 12 are each other's parent.
        let snapshot = ProcessSnapshot(takenAt: Date(), processes: [
            process(1, 0), process(3, 1), process(5, 1), process(7, 42), process(9, 5), process(11, 12), process(12, 11),
        ], ranAsRoot: false)
        let tree = snapshot.treeOrdered()
        #expect(tree.map { $0.process.pid } == [1, 3, 5, 9, 7, 11, 12])
        #expect(tree.map { $0.depth } == [0, 1, 1, 2, 0, 0, 0])
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
        let folder = FileManager.default.temporaryDirectory.appending(path: "hector-quarantine-\(UUID().uuidString)")
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
        let file = FileManager.default.temporaryDirectory.appending(path: "hector-quarantined-\(UUID().uuidString)")
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

@Suite struct ProcessVisibilityTests {
    private func process(_ pid: Int32, user: UInt32) -> RunningProcess {
        var process = RunningProcess(pid: pid, parentPID: 1, userID: user, name: "p\(pid)")
        process.arguments = ["/bin/p\(pid)", "--token", "secret-\(pid)"]
        return process
    }

    @Test func otherUsersArgumentsStayWithRoot() {
        let snapshot = ProcessSnapshot(takenAt: Date(), processes: [process(1, user: 0), process(2, user: 501), process(3, user: 502)],
                                       ranAsRoot: true)
        let seenBy501 = snapshot.visible(to: 501)
        #expect(seenBy501.processes.map(\.arguments.isEmpty) == [false, false, true])
        #expect(seenBy501.processes.count == 3)
        #expect(seenBy501.processes[2].name == "p3")
        #expect(snapshot.visible(to: 0).processes.allSatisfy { !$0.arguments.isEmpty })
    }
}

@Suite struct ProcessNameTests {
    @Test func versionNamedExecutablesTakeTheirFolderName() {
        #expect(SocketCollector.displayName(kernelName: "2.1.281", path: "/Users/alex/.local/share/claude/versions/2.1.281") == "claude")
        #expect(SocketCollector.displayName(kernelName: nil, path: "/opt/tools/node/v20.11.0/bin/v20.11.0") == "node")
        #expect(SocketCollector.displayName(kernelName: "1.2.3-beta", path: "/opt/acme/releases/1.2.3-beta") == "acme")
    }

    @Test func ordinaryNamesAreKept() {
        #expect(SocketCollector.displayName(kernelName: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari") == "Safari")
        #expect(SocketCollector.displayName(kernelName: "python3.12", path: "/usr/local/bin/python3.12") == "python3.12")
        #expect(SocketCollector.displayName(kernelName: "2.1.281", path: nil) == "2.1.281")
        #expect(SocketCollector.displayName(kernelName: nil, path: nil) == nil)
    }

    @Test func versionShapes() {
        for text in ["2.1.281", "v20.11.0", "1.0", "1.2.3-rc1"] { #expect(SocketCollector.looksLikeVersion(text), "\(text)") }
        for text in ["python3.12", "v8", "2", "x1.2", "1.2b", "Safari"] { #expect(!SocketCollector.looksLikeVersion(text), "\(text)") }
    }
}

@Suite struct ProcessFilterTests {
    private func process(_ pid: Int32, parent: Int32, path: String) -> RunningProcess {
        RunningProcess(pid: pid, parentPID: parent, userID: 501, name: "p\(pid)", executablePath: path)
    }

    @Test func appleCodeIsTheSIPProtectedFolders() {
        #expect(process(1, parent: 0, path: "/sbin/launchd").isAppleSystemCode)
        #expect(process(2, parent: 1, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder").isAppleSystemCode)
        #expect(!process(3, parent: 1, path: "/usr/local/bin/tool").isAppleSystemCode)
        #expect(!process(4, parent: 1, path: "/Applications/Safari.app/Contents/MacOS/Safari").isAppleSystemCode)
        #expect(!RunningProcess(pid: 5, parentPID: 1, userID: 0, name: "x").isAppleSystemCode)
    }

    @Test func ancestorsConnectTheTree() {
        let snapshot = ProcessSnapshot(takenAt: Date(), processes: [
            process(1, parent: 0, path: "/sbin/launchd"),
            process(10, parent: 1, path: "/System/Library/Terminal"),
            process(11, parent: 10, path: "/bin/zsh"),
            process(12, parent: 11, path: "/opt/tool"),
            process(20, parent: 1, path: "/usr/libexec/other"),
        ], ranAsRoot: false)
        #expect(snapshot.withAncestors([12]) == [12, 11, 10, 1])
        #expect(snapshot.withAncestors([]) == [])
    }
}

@Suite struct ProcessControlTests {
    private func process(pid: Int32, userID: UInt32 = getuid(), startedAt: Date? = Date(timeIntervalSince1970: 1_000)) -> RunningProcess {
        RunningProcess(pid: pid, parentPID: 1, userID: userID, name: "test", startedAt: startedAt)
    }

    @Test func offersQuitOnlyForTheUsersOwnProcesses() {
        #expect(ProcessControl.canQuit(process(pid: 4242, userID: 501), userID: 501, ownPID: 1))
        #expect(!ProcessControl.canQuit(process(pid: 4242, userID: 0), userID: 501, ownPID: 1))
        #expect(!ProcessControl.canQuit(process(pid: 4242, userID: 502), userID: 501, ownPID: 1))
        // Root running the app is not a reason to offer it.
        #expect(!ProcessControl.canQuit(process(pid: 4242, userID: 0), userID: 0, ownPID: 1))
        #expect(!ProcessControl.canQuit(process(pid: 4242, userID: 501), userID: 501, ownPID: 4242))
        #expect(!ProcessControl.canQuit(process(pid: 1, userID: 501), userID: 501, ownPID: 2))
        #expect(!ProcessControl.canQuit(process(pid: 4242, userID: 501, startedAt: nil), userID: 501, ownPID: 1))
    }

    @Test func quitsAChildAndRefusesAReusedPID() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        let info = try #require(ProcessCollector.basicInfo(of: child.processIdentifier))
        let seen = RunningProcess(pid: child.processIdentifier, parentPID: info.parentPID, userID: info.userID,
                                  name: "sleep", startedAt: info.startedAt)

        // Same PID, another start time: a different process now.
        var older = seen
        older.startedAt = seen.startedAt?.addingTimeInterval(-60)
        #expect(throws: ProcessControl.Refusal.replaced) { try ProcessControl.terminate(older) }
        #expect(child.isRunning)

        try ProcessControl.terminate(seen)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
        #expect(throws: ProcessControl.Refusal.exited) { try ProcessControl.verify(seen) }
    }
}
