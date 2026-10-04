import SwiftUI

/// The sidebar is navigation only: one entry per screen, short and static. Filtering by app
/// happens on the Connections screen.
enum SidebarItem: Hashable {
    /// Netbite's map and list of connections, for every app or the one in `WindowState.appFilter`.
    case allApps
    case blocklists
    case persistence
    case processes
    case checkup
    case keyboardTaps
    case captureDevices
}

struct SidebarView: View {
    @Environment(ConnectionMonitor.self) private var monitor
    @Environment(BlockingController.self) private var blocking
    @Environment(SecurityController.self) private var security
    @Environment(CheckupController.self) private var checkup
    @Environment(PrivacyController.self) private var privacy
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(spacing: 0) {
            list
            ProtectionStatusFooter(selection: $selection)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section("Netbite") {
                SidebarLabel("Connections", subtitle: connectionsSubtitle, systemImage: "globe", tint: .hectorOK)
                    .tag(SidebarItem.allApps)
                SidebarLabel("Blocklists", subtitle: blocklistSubtitle, systemImage: "nosign", tint: .hectorDanger) {
                    if blocking.pendingChanges > 0 {
                        StatusPill("\(blocking.pendingChanges)", kind: .warning, systemImage: "clock", size: .small)
                            .help("Pending changes")
                    }
                }
                .tag(SidebarItem.blocklists)
            }
            Section("Security") {
                SidebarLabel("Persistence", subtitle: persistenceSubtitle, systemImage: "arrow.triangle.2.circlepath")
                    .tag(SidebarItem.persistence)
                SidebarLabel("Processes", subtitle: processesSubtitle, systemImage: "cpu")
                    .tag(SidebarItem.processes)
                SidebarLabel("Checkup", subtitle: checkupSubtitle, systemImage: "checklist")
                    .tag(SidebarItem.checkup)
            }
            Section("Privacy") {
                PrivacySidebarRows(privacy: privacy)
            }
        }
        .listStyle(.sidebar)
    }

    private var connectionsSubtitle: String {
        "\(monitor.apps.count) apps · \(monitor.liveConnectionCount) live"
    }

    private var persistenceSubtitle: String {
        guard let report = security.persistence else { return security.isScanningPersistence ? "Scanning…" : "Launch items, extensions…" }
        let noted = report.items.filter { !$0.notes.isEmpty }.count
        return "\(report.items.count) items" + (noted > 0 ? " · \(noted) to review" : "")
    }

    private var processesSubtitle: String {
        guard let snapshot = security.processes else { return "Tree, signatures, flags" }
        let flagged = security.processFlags.values.filter { !$0.isEmpty }.count
        return "\(snapshot.processes.count) running" + (flagged > 0 ? " · \(flagged) flagged" : "")
    }

    private var checkupSubtitle: String {
        guard let report = checkup.report else { return checkup.isRunning ? "Checking…" : "SIP, FileVault, firewall…" }
        let toReview = report.count(.fail) + report.count(.warning)
        return "\(report.passedCount) of \(report.results.count) pass" + (toReview > 0 ? " · \(toReview) to review" : "")
    }

    private var blocklistSubtitle: String {
        guard blocking.isHelperReady else { return "Helper not installed" }
        return blocking.enforcedSummary ?? "Nothing blocked"
    }
}
