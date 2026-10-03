import SwiftUI

enum SidebarItem: Hashable {
    case allApps
    case app(AppGroup.ID)
    case blocklists
    case persistence
    case processes
    case keyboardTaps
    case captureDevices
}

struct SidebarView: View {
    @Environment(ConnectionMonitor.self) private var monitor
    @Environment(BlockingController.self) private var blocking
    @Environment(SecurityController.self) private var security
    @Binding var selection: SidebarItem?
    /// App owning the line hovered on the map or in the list.
    let highlightedAppID: AppGroup.ID?

    var body: some View {
        let apps = monitor.sortedApps
        List(selection: $selection) {
            Section {
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
            }
            Section("Privacy") {
                PrivacySidebarRows()
            }
            Section("Apps") {
                SidebarLabel("All apps", subtitle: "\(apps.count) apps · \(monitor.liveConnectionCount) live",
                             systemImage: "square.grid.2x2", tint: .hectorOK)
                .tag(SidebarItem.allApps)

                ForEach(apps.filter { $0.kind == .app }) { app in
                    AppSidebarRow(app: app, highlighted: app.id == highlightedAppID)
                        .tag(SidebarItem.app(app.id))
                }
            }
            Section("System & tools") {
                ForEach(apps.filter { $0.kind == .system }) { app in
                    AppSidebarRow(app: app, highlighted: app.id == highlightedAppID)
                        .tag(SidebarItem.app(app.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { ProtectionStatusFooter(selection: $selection) }
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

    private var blocklistSubtitle: String {
        let applied = blocking.applied
        let rules = applied.rules.filter(\.isEnabled).count
        let countries = applied.blockedCountries.count
        guard blocking.isHelperReady else { return "Helper not installed" }
        return "\(rules) rules · \(countries) countr\(countries == 1 ? "y" : "ies")"
    }
}

private struct AppSidebarRow: View {
    let app: AppGroup
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: app, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).fontWeight(.medium).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Sparkline(values: app.activity, color: app.liveCount > 0 ? Color.hectorOK : Color.hectorNeutral)
                .frame(width: 40, height: 16)
        }
        .padding(.vertical, 2)
        .background {
            // The app that owns the line hovered on the map or in the list.
            if highlighted {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(Color.hectorOKWash)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.hectorOK.opacity(0.6), lineWidth: 1))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -2)
            }
        }
        .motion(Motion.quick, value: highlighted)
    }

    private var subtitle: String {
        let count = app.destinations.count
        let live = app.liveCount
        return "\(count) dest." + (live > 0 ? " · \(live) live" : "")
    }
}
