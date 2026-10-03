import SwiftUI

enum SidebarItem: Hashable {
    case allApps
    case app(AppGroup.ID)
    case blocklists
}

struct SidebarView: View {
    @Environment(ConnectionMonitor.self) private var monitor
    @Environment(BlockingController.self) private var blocking
    @Binding var selection: SidebarItem?
    /// App owning the line hovered on the map or in the list.
    let highlightedAppID: AppGroup.ID?

    var body: some View {
        let apps = monitor.sortedApps
        List(selection: $selection) {
            Section {
                SidebarLabel("Blocklists", subtitle: blocklistSubtitle, systemImage: "nosign", tint: .hexDanger) {
                    if blocking.pendingChanges > 0 {
                        StatusPill("\(blocking.pendingChanges)", kind: .warning, systemImage: "clock", size: .small)
                            .help("Pending changes")
                    }
                }
                .tag(SidebarItem.blocklists)
            }
            Section("Apps") {
                SidebarLabel("All apps", subtitle: "\(apps.count) apps · \(monitor.liveConnectionCount) live",
                             systemImage: "square.grid.2x2", tint: .hexOK)
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
            Sparkline(values: app.activity, color: app.liveCount > 0 ? Color.hexOK : Color.hexNeutral)
                .frame(width: 40, height: 16)
        }
        .padding(.vertical, 2)
        .background {
            // The app that owns the line hovered on the map or in the list.
            if highlighted {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(Color.hexOKWash)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.hexOK.opacity(0.6), lineWidth: 1))
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
