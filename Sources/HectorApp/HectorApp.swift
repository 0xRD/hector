import AppKit
import HectorCore
import SwiftUI

@main
struct HectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // First, so the controllers below find Netbite's blocklist and API key under Hector's names.
    // Stored properties are initialized in declaration order.
    private let migrated = LegacyMigration.run()
    private let preferences = AppPreferences()
    // Created once with the app; see WindowState for why this is not `@State`.
    private let monitor = ConnectionMonitor()
    private let windowState = WindowState()
    private let blocking = BlockingController()
    private let security = SecurityController()
    private let checkup = CheckupController()
    private let privacy = PrivacyController()

    var body: some Scene {
        Window("Hector", id: "main") {
            ContentView()
                .environment(monitor)
                .environment(windowState)
                .environment(blocking)
                .environment(security)
                .environment(checkup)
                .environment(privacy)
                .tint(.hectorOK)
                // English words in dates and numbers formatted by SwiftUI (see `Display`).
                .environment(\.locale, Display.locale)
                // Small enough for a 13-inch screen with the Dock showing.
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    monitor.start()
                    await blocking.refresh()
                }
        }
        .defaultSize(width: 1440, height: 920)
        // Without it the window could be resized below the content's minimum size; SwiftUI then
        // centered the oversized content, pushing the top of the sidebar above the window (the
        // sidebar looked empty or stuck at the bottom) and cutting off the top of the map.
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Uninstall Hector…") { windowState.showUninstall = true }
            }
        }

        // Read-only on purpose: SwiftUI writes back whatever AppKit reports about the item, and
        // when macOS hides it (a full menu bar behind the notch), each write rebuilt the scenes,
        // which re-inserted the item, which macOS hid again: an endless loop at 100% CPU, in the
        // builds made with the macOS 15 SDK. Only Settings changes this preference.
        MenuBarExtra(isInserted: Binding(get: { preferences.keepsRunningInMenuBar }, set: { _ in })) {
            MenuBarPanel()
                .environment(monitor)
                .environment(blocking)
                .environment(privacy)
                .environment(\.locale, Display.locale)
                .tint(.hectorTint)
        } label: {
            MenuBarLabel()
                .environment(blocking)
                .environment(privacy)
                // The label lives as long as the icon, window or not: what must keep running
                // starts here.
                .task {
                    monitor.start()
                    privacy.startMonitoring()
                    await blocking.refresh()
                    #if DEBUG
                    await DebugSnapshot.renderPanelIfRequested(MenuBarPanel()
                        .environment(monitor).environment(blocking).environment(privacy)
                        .environment(\.locale, Display.locale))
                    #endif
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(security)
                .environment(windowState)
                .environment(preferences)
                .tint(.hectorTint)
                .environment(\.locale, Display.locale)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIconArtwork.render(size: 512)
        if MenuBarMode.isEnabled && MenuBarMode.launchedAtLogin {
            // Started at login: the menu bar only, no window in the way.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.identifier?.rawValue == "main" || $0.title == "Hector" }.forEach { $0.close() }
            }
        } else {
            // Needed when launched as a bare executable (`swift run`) rather than from Hector.app.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // After the window is gone, not while it closes.
            DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarMode.updateActivationPolicy() } }
        }
        #if DEBUG
        DebugSnapshot.renderBrandIfRequested()
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MenuBarMode.isEnabled }

    /// Clicking the Dock icon or opening the app again shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }
}

/// The app icon, drawn in code so the repository needs no binary assets.
///
/// Hector on the walls of Troy: a squircle on the macOS icon grid (412 pt body in a 512 pt
/// canvas) with a lavender-to-cream dawn sky, a honey sun rising behind his shoulder, the mark,
/// and a sandstone rampart he peeks over. Warm, calm, a little vintage.
struct AppIconArtwork: View {
    private static let canvas: CGFloat = 512
    private static let bodySize: CGFloat = 412
    private static let corner: CGFloat = 92
    /// Side of the mark inside the body.
    private static let markSize: CGFloat = 288
    /// Top of the rampart, from the top of the body.
    private static let wallTop: CGFloat = 286

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        ZStack {
            shape
                .fill(Color.brandCream)
                .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)
            scene
                .clipShape(shape)
            shape.strokeBorder(Color.brandPlum.opacity(0.12), lineWidth: 2)
        }
        .frame(width: Self.bodySize, height: Self.bodySize)
        .frame(width: Self.canvas, height: Self.canvas)
    }

    private var scene: some View {
        let half: CGFloat = Self.bodySize / 2
        let wallHeight: CGFloat = Self.bodySize - Self.wallTop
        let sky = LinearGradient(colors: [.brandSky, .brandCream], startPoint: .top, endPoint: .bottom)
        return ZStack {
            Rectangle().fill(sky)
            Circle()
                .fill(Color.brandHoney)
                .frame(width: 104, height: 104)
                .position(x: 302, y: 116)
            HectorMark(
                lineWidth: 0.95,
                ink: .brandPlum,
                helmet: [.brandLavender, .brandLavenderDeep],
                face: .brandCream,
                crest: .brandClay,
                detailed: true
            )
            .frame(width: Self.markSize, height: Self.markSize)
            .shadow(color: Color.brandPlum.opacity(0.18), radius: 10, x: 0, y: 6)
            .position(x: half, y: 36 + Self.markSize / 2)
            RampartPattern()
                .frame(width: Self.bodySize, height: wallHeight)
                .position(x: half, y: Self.wallTop + wallHeight / 2)
        }
        .frame(width: Self.bodySize, height: Self.bodySize)
    }

    @MainActor
    static func render(size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconArtwork().scaleEffect(size / 512).frame(width: size, height: size))
        renderer.scale = 2
        return renderer.nsImage
    }
}
