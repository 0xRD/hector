import Foundation
import Testing
@testable import HectorCore

@Suite struct KnownSetTests {
    @Test func firstAdmissionAnnouncesNothing() {
        var set = KnownSet()
        #expect(set.admit(["a", "b"], group: "agents").isEmpty)
        #expect(set.admit(["a", "b", "c"], group: "agents") == ["c"])
        #expect(set.admit(["a", "c"], group: "agents").isEmpty)
        // A removed key that comes back is not new.
        #expect(set.admit(["b"], group: "agents").isEmpty)
    }

    @Test func groupsAreBaselinedSeparately() {
        var set = KnownSet()
        _ = set.admit(["a"], group: "files")
        // Login items read for the first time (the helper was just installed): nothing announced.
        #expect(set.admit(["x", "y"], group: "login").isEmpty)
        #expect(set.admit(["x", "y", "z"], group: "login") == ["z"])
        #expect(set.isKnown("a", group: "files"))
        #expect(!set.isKnown("a", group: "login"))
        set.reset(group: "login")
        #expect(set.admit(["w"], group: "login").isEmpty)
    }

    @Test func anEmptyFirstAdmissionStillBaselines() {
        var set = KnownSet()
        #expect(set.admit([], group: "taps").isEmpty)
        #expect(set.admit(["t"], group: "taps") == ["t"])
    }

    @Test func savesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hector-known-\(UUID().uuidString)/known.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = KnownSetFile(url: url)
        #expect(file.load() == KnownSet())
        var set = KnownSet()
        _ = set.admit(["a"], group: "g")
        file.save(set)
        var loaded = file.load()
        #expect(loaded == set)
        #expect(loaded.admit(["a", "b"], group: "g") == ["b"])
        try Data("garbage".utf8).write(to: url)
        #expect(file.load() == KnownSet())
    }

    @Test func folderWatcherReportsANewFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hector-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (stream, continuation) = AsyncStream.makeStream(of: [String].self)
        let watcher = FolderWatcher(paths: [folder.resolvingSymlinksInPath().path], latency: 0.1) { continuation.yield($0) }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try Data("x".utf8).write(to: folder.appending(path: "com.example.agent.plist"))
        let first = await withTaskGroup(of: [String]?.self) { group in
            group.addTask { await stream.first { _ in true } }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        #expect(first?.isEmpty == false)
    }
}
