import HectorCore
import SwiftUI

/// The Privacy entries of the sidebar: keyboard taps, camera and microphone.
///
/// Takes the controller as a parameter: sidebar rows live in an AppKit outline view that may
/// rebuild them before SwiftUI attaches the environment, and a missing environment object crashes.
struct PrivacySidebarRows: View {
    let privacy: PrivacyController

    var body: some View {
        SidebarLabel("Keyboard taps", subtitle: tapsSubtitle, systemImage: "keyboard")
            .tag(SidebarItem.keyboardTaps)
        SidebarLabel("Camera & mic", subtitle: devicesSubtitle, systemImage: "web.camera") {
            if !privacy.devicesInUse.isEmpty {
                StatusPill("On", kind: .warning, systemImage: "circle.fill", size: .small)
                    .help(privacy.devicesInUse.map(\.name).joined(separator: ", "))
            }
        }
        .tag(SidebarItem.captureDevices)
    }

    private var tapsSubtitle: String {
        guard let taps = privacy.taps else { return "Apps reading keystrokes" }
        // Only what receives keystrokes counts: switched-off taps receive nothing.
        let apps = Set(taps.filter(\.isEnabled).map(\.tapping.pid)).count
        return apps == 0 ? "Nobody listening" : (apps == 1 ? "1 app listening" : "\(apps) apps listening")
    }

    private var devicesSubtitle: String {
        guard privacy.isMonitoring else { return "On and off log" }
        let inUse = privacy.devicesInUse
        if inUse.isEmpty { return "Nothing in use" }
        let kinds: [String] = Set(inUse.map(\.kind.label)).sorted()
        return kinds.joined(separator: " and ") + " in use"
    }
}
