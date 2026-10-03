#if DEBUG
import AppKit

/// Development aid, debug builds only: lets a script check the UI without screen-recording rights.
///
/// - `NETBITE_SNAPSHOT=/path/shot.png` writes the main window to a PNG after
///   `NETBITE_SNAPSHOT_DELAY` seconds (default 6), then quits.
/// - `NETBITE_DEBUG_HOVER=N` pretends the pointer hovers the N-th line of the map.
/// - `NETBITE_DEBUG_SELECT=N` selects the N-th line of the map.
/// - `NETBITE_DEBUG_BLOCKLISTS=1` opens the Blocklists screen.
@MainActor
enum DebugSnapshot {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var hoverIndex: Int? { environment["NETBITE_DEBUG_HOVER"].flatMap(Int.init) }
    static var selectIndex: Int? { environment["NETBITE_DEBUG_SELECT"].flatMap(Int.init) }
    static var opensBlocklists: Bool { environment["NETBITE_DEBUG_BLOCKLISTS"] != nil }

    static func scheduleIfRequested() {
        guard let path = environment["NETBITE_SNAPSHOT"] else { return }
        let delay = environment["NETBITE_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 6
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    private static func write(to url: URL) {
        guard let window = NSApp.windows.first(where: \.isVisible),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("netbite: no window to snapshot\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
