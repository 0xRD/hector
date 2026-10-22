import AppKit
import HectorCore
import Observation
import SwiftUI
import UserNotifications

/// What Hector can notify about. Each is off until the user turns it on in Settings.
enum AlertKind: String, CaseIterable, Identifiable {
    case captureDevices
    case keyboardTaps
    case persistence
    case newApps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureDevices: "Camera or microphone turns on"
        case .keyboardTaps: "An app starts reading keystrokes"
        case .persistence: "Something new starts by itself"
        case .newApps: "An app connects for the first time"
        }
    }

    var detail: String {
        switch self {
        case .captureDevices: "Names the app when macOS tells which one."
        case .keyboardTaps: "A new active keyboard tap, checked every 30 seconds."
        case .persistence: "A new launch agent, daemon, login item or extension, with its signature. Launch folders are watched as they change."
        case .newApps: "The first connection of an app or process Hector has never seen connect."
        }
    }

    /// The screen a click on the notification opens.
    var screen: SidebarItem {
        switch self {
        case .captureDevices: .captureDevices
        case .keyboardTaps: .keyboardTaps
        case .persistence: .persistence
        case .newApps: .allApps
        }
    }

    fileprivate var defaultsKey: String { "notify.\(rawValue)" }
}

/// Posts Hector's notifications through the system's Notification Center, only for the kinds the
/// user turned on. Nothing leaves the Mac.
@MainActor
@Observable
final class Notifier: NSObject {
    enum Permission: Equatable {
        case notAsked
        case allowed
        case denied
        /// Run outside Hector.app (`swift run`): Notification Center needs a bundle.
        case unavailable
    }

    private(set) var enabled: Set<AlertKind>
    private(set) var permission: Permission = .notAsked
    /// Opens the main window on a screen; set by a view that can open windows.
    @ObservationIgnored var openScreen: ((SidebarItem) -> Void)?
    /// Called after a kind is turned on or off.
    @ObservationIgnored var onSettingsChange: (() -> Void)?
    /// When each notification key was last posted, so a flapping device does not repeat itself.
    @ObservationIgnored private var lastPosted: [String: Date] = [:]

    private static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    override init() {
        enabled = Set(AlertKind.allCases.filter { UserDefaults.standard.bool(forKey: $0.defaultsKey) })
        super.init()
        guard Self.isBundled else {
            permission = .unavailable
            return
        }
        UNUserNotificationCenter.current().delegate = self
        Task {
            await refreshPermission()
            // Turned on while macOS had not been asked yet (for instance its answer was reset).
            if !enabled.isEmpty && permission == .notAsked { await requestPermission() }
        }
    }

    func isEnabled(_ kind: AlertKind) -> Bool { enabled.contains(kind) }

    /// Turning a kind on asks macOS for permission the first time.
    func setEnabled(_ kind: AlertKind, _ on: Bool) {
        if on { enabled.insert(kind) } else { enabled.remove(kind) }
        UserDefaults.standard.set(on, forKey: kind.defaultsKey)
        if on && permission == .notAsked { Task { await requestPermission() } }
        onSettingsChange?()
    }

    func refreshPermission() async {
        guard Self.isBundled else { return }
        // Only the status crosses over: the settings object is not Sendable (Swift 6.1 refuses it).
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
        switch status {
        case .authorized, .provisional: permission = .allowed
        case .denied: permission = .denied
        default: permission = .notAsked
        }
    }

    private func requestPermission() async {
        guard Self.isBundled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshPermission()
    }

    /// System Settings → Notifications, to allow Hector after refusing once.
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts a notification when `kind` is on. `key` identifies what it is about: the same key
    /// is not posted twice within `quietPeriod`.
    func post(_ kind: AlertKind, title: String, body: String, key: String, quietPeriod: TimeInterval = 60) {
        guard enabled.contains(kind), Self.isBundled, permission != .denied else { return }
        let fullKey = "\(kind.rawValue):\(key)"
        let now = Date()
        if let last = lastPosted[fullKey], now.timeIntervalSince(last) < quietPeriod { return }
        lastPosted[fullKey] = now
        if lastPosted.count > 500 { lastPosted = lastPosted.filter { now.timeIntervalSince($0.value) < quietPeriod } }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = kind.rawValue
        content.userInfo = ["kind": kind.rawValue]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    fileprivate func open(kindNamed name: String?) {
        guard let name, let kind = AlertKind(rawValue: name) else { return }
        openScreen?(kind.screen)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Shown even while Hector is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let kind = response.notification.request.content.userInfo["kind"] as? String
        await MainActor.run { self.open(kindNamed: kind) }
    }
}

/// Lets a click on a notification open the main window on its screen, and starts the alerts.
/// Applied to the window and to the menu bar icon, whichever exists.
struct AlertWiring: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let notifier: Notifier
    let alerts: AlertWatcher
    let state: WindowState
    let security: SecurityController
    let privacy: PrivacyController
    let monitor: ConnectionMonitor

    func body(content: Content) -> some View {
        content.task {
            notifier.openScreen = { screen in
                state.sidebarSelection = screen
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate()
            }
            alerts.start(notifier: notifier, security: security, privacy: privacy, monitor: monitor)
        }
    }
}
