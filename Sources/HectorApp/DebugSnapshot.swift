#if DEBUG
import AppKit

/// Development aid, debug builds only: lets a script check the UI without screen-recording rights.
///
/// - `HECTOR_SNAPSHOT=/path/shot.png` writes the main window to a PNG after
///   `HECTOR_SNAPSHOT_DELAY` seconds (default 6), then quits.
/// - `HECTOR_DEBUG_HOVER=N` pretends the pointer hovers the N-th line of the map.
/// - `HECTOR_DEBUG_SELECT=N` selects the N-th line of the map.
/// - `HECTOR_DEBUG_BLOCKLISTS=1` opens the Blocklists screen.
/// - `HECTOR_DEBUG_SETTINGS=1` opens the Settings window.
/// - `HECTOR_DEBUG_SCREEN=NAME` opens a screen: blocklists, persistence, processes, checkup,
///   taps or devices.
@MainActor
enum DebugSnapshot {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var hoverIndex: Int? { environment["HECTOR_DEBUG_HOVER"].flatMap(Int.init) }
    static var selectIndex: Int? { environment["HECTOR_DEBUG_SELECT"].flatMap(Int.init) }
    static var opensBlocklists: Bool { environment["HECTOR_DEBUG_BLOCKLISTS"] != nil }

    static var screen: SidebarItem? {
        if opensBlocklists { return .blocklists }
        switch environment["HECTOR_DEBUG_SCREEN"] {
        case "blocklists": return .blocklists
        case "persistence": return .persistence
        case "processes": return .processes
        case "checkup": return .checkup
        case "taps": return .keyboardTaps
        case "devices": return .captureDevices
        default: return nil
        }
    }

    static var opensSettings: Bool { environment["HECTOR_DEBUG_SETTINGS"] != nil }

    static func scheduleIfRequested() {
        guard let path = environment["HECTOR_SNAPSHOT"] else { return }
        let delay = environment["HECTOR_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 6
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
            FileHandle.standardError.write(Data("hector: no window to snapshot\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
