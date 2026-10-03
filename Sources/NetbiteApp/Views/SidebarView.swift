import SwiftUI

enum SidebarItem: Hashable {
    case allApps
    case app(AppGroup.ID)
}

struct SidebarView: View {
    @Environment(ConnectionMonitor.self) private var monitor
    @Binding var selection: SidebarItem?
    /// App owning the line hovered on the map or in the list.
    let highlightedAppID: AppGroup.ID?

    var body: some View {
        let apps = monitor.sortedApps
        List(selection: $selection) {
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
