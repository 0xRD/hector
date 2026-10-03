import SwiftUI

enum SidebarItem: Hashable {
    case allApps
    case app(AppGroup.ID)
    case blocklists
    case persistence
    case processes
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
                HStack(spacing: 10) {
                    Image(systemName: "nosign")
                        .frame(width: 26, height: 26)
                        .foregroundStyle(Color.netbiteBlock)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Blocklists").fontWeight(.medium)
                        Text(blocklistSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if blocking.pendingChanges > 0 {
                        Text("\(blocking.pendingChanges)")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 6)
                            .background(Color.orange.opacity(0.25), in: Capsule())
                            .help("Pending changes")
                    }
                }
                .padding(.vertical, 2)
                .tag(SidebarItem.blocklists)
            }
            Section("Security") {
                SecuritySidebarRow(title: "Persistence", symbol: "arrow.triangle.2.circlepath", subtitle: persistenceSubtitle)
                    .tag(SidebarItem.persistence)
                SecuritySidebarRow(title: "Processes", symbol: "cpu", subtitle: processesSubtitle)
                    .tag(SidebarItem.processes)
            }
            Section("Apps") {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("All apps").fontWeight(.medium)
                        Text("\(apps.count) apps · \(monitor.liveConnectionCount) live")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
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
            Sparkline(values: app.activity, color: app.liveCount > 0 ? .netbiteAccent : .secondary)
                .frame(width: 40, height: 16)
        }
        .padding(.vertical, 2)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.netbiteAccent, lineWidth: 1.5)
                    .background(Color.netbiteAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -2)
            }
        }
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }

    private var subtitle: String {
        let count = app.destinations.count
        let live = app.liveCount
        return "\(count) dest." + (live > 0 ? " · \(live) live" : "")
    }
}

private struct SecuritySidebarRow: View {
    let title: String
    let symbol: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
