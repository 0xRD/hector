#if DEBUG
import AppKit
import SwiftUI

/// Development aid, debug builds only: lets a script check the UI without screen-recording rights.
///
/// - `HECTOR_SNAPSHOT=/path/shot.png` writes the main window to a PNG after
///   `HECTOR_SNAPSHOT_DELAY` seconds (default 6), then quits.
/// - `HECTOR_DEBUG_HOVER=N` pretends the pointer hovers the N-th line of the map.
/// - `HECTOR_DEBUG_SELECT=N` selects the N-th line of the map.
/// - `HECTOR_DEBUG_BLOCKLISTS=1` opens the Blocklists screen.
/// - `HECTOR_DEBUG_COUNTRY=US` filters the map and the list to one country;
///   `HECTOR_DEBUG_HOVER_COUNTRY=US` hovers that country's bubble on the world view.
/// - `HECTOR_DEBUG_SETTINGS=1` opens the Settings window.
/// - `HECTOR_DEBUG_SCREEN=NAME` opens a screen: blocklists, persistence, processes, checkup,
///   taps or devices.
/// - `HECTOR_DEBUG_PROCESS=PID` selects that process on the Processes screen and shows its details.
/// - `HECTOR_APPEARANCE=light` or `dark` forces the appearance, whatever the system uses.
/// - `HECTOR_DEMO=1` shows fixed sample data instead of this Mac's (see `DemoData`).
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

    static var country: String? { environment["HECTOR_DEBUG_COUNTRY"] }
    static var hoverCountry: String? { environment["HECTOR_DEBUG_HOVER_COUNTRY"] }
    static var processID: Int32? { environment["HECTOR_DEBUG_PROCESS"].flatMap(Int32.init) }
    static var opensSettings: Bool { environment["HECTOR_DEBUG_SETTINGS"] != nil }

    static func scheduleIfRequested() {
        switch environment["HECTOR_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if environment["HECTOR_DEBUG_CLOSE_WINDOW"] != nil {
            // As if the user closed the window: Hector should stay in the menu bar.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                NSApp.windows.filter { $0.identifier?.rawValue == "main" || $0.title == "Hector" }.forEach { $0.close() }
            }
        }
        guard let path = environment["HECTOR_SNAPSHOT"] else { return }
        let delay = environment["HECTOR_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 6
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    /// `HECTOR_RENDER_BRAND=/some/folder` writes the app icon and the wordmark (light and dark)
    /// as PNGs into that folder, then quits. `scripts/render-brand.sh` uses it for the README.
    static func renderBrandIfRequested() {
        guard let folder = environment["HECTOR_RENDER_BRAND"] else { return }
        let directory = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let icon = ImageRenderer(content: AppIconArtwork().scaleEffect(0.5).frame(width: 256, height: 256))
        icon.scale = 2
        savePNG(icon.cgImage, to: directory.appending(path: "hector-icon.png"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let resolved = NSAppearance(named: appearance) else { continue }
            NSApp.appearance = resolved
            resolved.performAsCurrentDrawingAppearance {
                let wordmark = ImageRenderer(content: HectorWordmark(size: 44).padding(4)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light))
                wordmark.scale = 2
                savePNG(wordmark.cgImage, to: directory.appending(path: "hector-wordmark-\(name).png"))
            }
        }
        NSApp.terminate(nil)
    }

    /// `HECTOR_DEBUG_PANEL=/path/panel.png` writes the menu bar panel, once the controllers have
    /// had a few seconds to fill it.
    static func renderPanelIfRequested<Content: View>(_ panel: Content) async {
        guard let path = environment["HECTOR_DEBUG_PANEL"] else { return }
        try? await Task.sleep(for: .seconds(6))
        let renderer = ImageRenderer(content: panel.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        savePNG(renderer.cgImage, to: URL(fileURLWithPath: path))
    }

    private static func savePNG(_ image: CGImage?, to url: URL) {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("hector: could not render \(url.lastPathComponent)\n".utf8))
            return
        }
        try? data.write(to: url)
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
