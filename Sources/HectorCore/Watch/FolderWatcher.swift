import CoreServices
import Foundation

/// Calls back when something changes in a few folders, through FSEvents: no polling, and folders
/// that do not exist yet are fine (FSEvents filters paths, it does not open them).
///
/// Changes are coalesced: one callback for a burst, `latency` seconds after it starts.
public final class FolderWatcher: @unchecked Sendable {
    public let paths: [String]
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "io.github.0xrd.hector.folder-watcher")
    private let onChange: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 2, onChange: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit { stop() }

    /// The folders where launchd jobs live, for the user and for the machine.
    public static func launchdFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [home.appending(path: "Library/LaunchAgents").path, "/Library/LaunchAgents", "/Library/LaunchDaemons",
         "/Library/StartupItems"]
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(eventPaths, to: NSArray.self)
                let changed = (0..<count).compactMap { array[$0] as? String }
                watcher.onChange(changed)
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    public func stop() {
        let stop = { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { stop() } else { queue.sync(execute: stop) }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()
}
