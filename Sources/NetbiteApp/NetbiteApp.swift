import AppKit
import SwiftUI

@main
struct NetbiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Created once with the app; see WindowState for why this is not `@State`.
    private let monitor = ConnectionMonitor()
    private let windowState = WindowState()

    var body: some Scene {
        Window("Netbite", id: "main") {
            ContentView()
                .environment(monitor)
                .environment(windowState)
                .tint(.netbiteAccent)
                .frame(minWidth: 1060, minHeight: 660)
                .task { monitor.start() }
        }
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from Netbite.app.
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
struct AppIconArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 112, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.11))
                .padding(50)
            NetbiteLogo(lineWidth: 1.6)
                .padding(120)
        }
        .frame(width: 512, height: 512)
        .environment(\.colorScheme, .dark)
    }

    @MainActor
    static func render(size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconArtwork().scaleEffect(size / 512).frame(width: size, height: size))
        renderer.scale = 2
        return renderer.nsImage
    }
}
