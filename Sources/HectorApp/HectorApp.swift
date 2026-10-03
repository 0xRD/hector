import AppKit
import HectorCore
import SwiftUI

@main
struct HectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // First, so the controllers below find Netbite's blocklist and API key under Hector's names.
    // Stored properties are initialized in declaration order.
    private let migrated = LegacyMigration.run()
    // Created once with the app; see WindowState for why this is not `@State`.
    private let monitor = ConnectionMonitor()
    private let windowState = WindowState()
    private let blocking = BlockingController()
    private let security = SecurityController()
    private let checkup = CheckupController()

    var body: some Scene {
        Window("Hector", id: "main") {
            ContentView()
                .environment(monitor)
                .environment(windowState)
                .environment(blocking)
                .environment(security)
                .environment(checkup)
                .tint(.hectorOK)
                .frame(minWidth: 1060, minHeight: 660)
                .task {
                    monitor.start()
                    await blocking.refresh()
                }
        }
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Uninstall Hector…") { windowState.showUninstall = true }
            }
        }

        Settings {
            SettingsView()
                .environment(security)
                .environment(windowState)
                .tint(.hectorTint)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from Hector.app.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIconArtwork.render(size: 512)
        NSApp.activate()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The app icon, drawn in code so the repository needs no binary assets.
///
/// The Hector icon: a plum squircle on the macOS icon grid (412 pt body in a 512 pt canvas),
/// a faint hexagon lattice, a lavender glow, and the mark: a friendly ghost in a hexagon seal,
/// with a honey spark breaking out of it.
struct AppIconArtwork: View {
    private static let canvas: CGFloat = 512
    private static let bodySize: CGFloat = 412
    private static let corner: CGFloat = 92

    var body: some View {
        ZStack {
            squircle
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8)
            HectorMark(
                lineWidth: 1.5,
                seal: [.brandLavender, .brandSage],
                ghost: .brandCream,
                eyes: .brandPlum,
                spark: .brandHoney
            )
            .frame(width: 272, height: 272)
            .shadow(color: Color.brandLavender.opacity(0.35), radius: 18, x: 0, y: 0)
        }
        .frame(width: Self.canvas, height: Self.canvas)
        .environment(\.colorScheme, .dark)
    }

    private var squircle: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        let fill = LinearGradient(colors: [.brandPlum, .brandNight], startPoint: .top, endPoint: .bottom)
        let glow = RadialGradient(
            colors: [Color.brandLavender.opacity(0.30), Color.brandLavender.opacity(0)],
            center: UnitPoint(x: 0.5, y: 0.42),
            startRadius: 0,
            endRadius: 210
        )
        return ZStack {
            shape.fill(fill)
            HexLattice(cell: 46, color: Color.brandCream.opacity(0.05), lineWidth: 1.5)
                .clipShape(shape)
            shape.fill(glow)
            shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 2)
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
