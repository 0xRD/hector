import AppKit
import HectorCore
import SwiftUI

/// Hector in the menu bar: it keeps running with its window closed, so the camera and microphone
/// log and the connection history go on, and the window opens from here.
///
/// Off in Settings → General, Hector behaves like an ordinary app again: closing the window quits.
enum MenuBarMode {
    static let key = "keepsRunningInMenuBar"

    static func register() {
        UserDefaults.standard.register(defaults: [key: true])
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Whether this launch was started by the system at login, where Hector should open in the
    /// menu bar only. Read from the launch event, as login items have always reported it.
    @MainActor static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// With the main window gone, Hector leaves the Dock and the app switcher; it comes back with
    /// the window.
    @MainActor static func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        let policy: NSApplication.ActivationPolicy = hasWindow || !isEnabled ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}

/// The icon in the menu bar: Hector's state at a glance, template-drawn like every menu bar icon.
struct MenuBarLabel: View {
    @Environment(BlockingController.self) private var blocking
    @Environment(PrivacyController.self) private var privacy

    var body: some View {
        HStack(spacing: 3) {
            // Hector keeps watch while something is blocked, and rests otherwise.
            Image(nsImage: Self.mark(gaze: blocking.enforcedSummary == nil ? .resting : .ahead))
            if !privacy.devicesInUse.filter({ $0.kind == .camera }).isEmpty {
                Image(systemName: "video.fill")
            }
            if !privacy.devicesInUse.filter({ $0.kind == .microphone }).isEmpty {
                Image(systemName: "mic.fill")
            }
        }
        .accessibilityLabel("Hector")
    }

    /// The mark in one ink on transparency, as a template image: macOS tints it for the menu bar,
    /// light or dark, like its own icons. The face is left clear so the visor reads at 18 pt.
    static func mark(gaze: HectorGaze) -> NSImage {
        if let cached = cache[gaze] { return cached }
        let renderer = ImageRenderer(content: HectorMark(lineWidth: 1.6, gaze: gaze, ink: .black, helmet: [.black, .black],
                                                         face: .clear, crest: .black, detailed: false)
            .frame(width: 18, height: 18))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "shield", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        cache[gaze] = image
        return image
    }

    @MainActor private static var cache: [HectorGaze: NSImage] = [:]
}

/// The panel under the icon.
struct MenuBarPanel: View {
    @Environment(ConnectionMonitor.self) private var monitor
    @Environment(BlockingController.self) private var blocking
    @Environment(PrivacyController.self) private var privacy
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                HectorMark(gaze: privacy.isMonitoring ? .ahead : .resting, detailed: true)
                    .frame(width: 26, height: 26)
                Text("Hector").font(Font.sectionTitle)
                Spacer()
                Text("\(monitor.liveConnectionCount) live").foregroundStyle(.secondary).monospacedDigit()
            }
            protection
            inUse
            if !privacy.events.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader("Camera & mic", style: .eyebrow)
                    ForEach(privacy.events.prefix(4)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                            Text(Display.time(event.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(event.summary).font(.caption).lineLimit(2)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Hector") { showWindow() }
                    .keyboardShortcut(.defaultAction)
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(Spacing.lg)
        .frame(width: 320)
    }

    private var protection: some View {
        let (title, detail, kind): (String, String, StatusKind) = switch blocking.helper {
        case .checking: ("Checking protection…", "", .neutral)
        case .notInstalled: ("Observe only", "Install the helper from Blocklists to block", .neutral)
        case .unreachable: ("Helper not answering", "Open Blocklists to retry", .danger)
        case .ready:
            if blocking.enforcedSummary == nil {
                ("Nothing is blocked", "Lists and rules are in Blocklists", .info)
            } else {
                ("Blocking on", [blocking.enforcedSummary, blocking.enforcedVolume].compactMap { $0 }.joined(separator: " · "), .ok)
            }
        }
        return HStack(spacing: Spacing.sm) {
            SymbolTile(kind == .ok ? "checkmark.shield.fill" : "shield", tint: kind.color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var inUse: some View {
        let devices = privacy.devicesInUse
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(devices) { device in
                    Label(device.name, systemImage: device.kind == .camera ? "video.fill" : "mic.fill")
                        .foregroundStyle(Color.hectorWarning)
                }
            }
        }
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Preferences the scenes read. Not `@AppStorage` or `@State`: see WindowState.
@MainActor
@Observable
final class AppPreferences {
    var keepsRunningInMenuBar: Bool {
        didSet {
            guard keepsRunningInMenuBar != oldValue else { return }
            UserDefaults.standard.set(keepsRunningInMenuBar, forKey: MenuBarMode.key)
        }
    }

    init() {
        MenuBarMode.register()
        keepsRunningInMenuBar = MenuBarMode.isEnabled
    }
}
