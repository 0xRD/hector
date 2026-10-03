import HectorCore
import SwiftUI

/// The Privacy entries of the sidebar: keyboard taps, camera and microphone.
struct PrivacySidebarRows: View {
    @Environment(PrivacyController.self) private var privacy

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
        return taps.count == 1 ? "1 tap" : "\(taps.count) taps"
    }

    private var devicesSubtitle: String {
        guard privacy.isMonitoring else { return "On and off log" }
        let inUse = privacy.devicesInUse
        if inUse.isEmpty { return "Nothing in use" }
        let kinds: [String] = Set(inUse.map(\.kind.label)).sorted()
        return kinds.joined(separator: " and ") + " in use"
    }
}
