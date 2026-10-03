import HectorCore
import SwiftUI

struct ContentView: View {
    @Environment(ConnectionMonitor.self) private var monitor
    @Environment(BlockingController.self) private var blocking
    @Environment(WindowState.self) private var state
    @Environment(SecurityController.self) private var security

    /// The network screens (map and list) as opposed to Blocklists and the security screens.
    private var isNetworkScreen: Bool {
        switch state.sidebarSelection {
        case .blocklists, .persistence, .processes: false
        default: true
        }
    }

    private var selectedAppID: AppGroup.ID? {
        if case .app(let id) = state.sidebarSelection { return id }
        return nil
    }

    var body: some View {
        @Bindable var monitor = monitor
        @Bindable var state = state
        let rows = visibleRows
        let groups = listGroups(from: rows)

        NavigationSplitView {
            SidebarView(selection: $state.sidebarSelection, highlightedAppID: state.hovered?.appID)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            if state.sidebarSelection == .blocklists {
                BlocklistView()
            } else if state.sidebarSelection == .persistence {
                PersistenceView()
            } else if state.sidebarSelection == .processes {
                ProcessesView()
            } else {
                VStack(spacing: 0) {
                    GeoBanner()
                    VSplitView {
                        // The map is width-bound (2.5:1); taller would only add empty bands.
                        mapCard(rows: rows)
                            .frame(minHeight: 220, idealHeight: 380, maxHeight: 480)
                        DestinationListView(groups: groups, selection: $state.selectedDestination, hovered: $state.hovered)
                            .frame(minHeight: 200)
                    }
                    Divider()
                    StatusBar()
                }
                .inspector(isPresented: $state.showInspector) {
                    DestinationDetailView(row: selectedRow, usedBy: usedBySelected)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(isNetworkScreen ? "\(monitor.liveConnectionCount) live connections" : "")
        .searchable(text: $state.search, placement: .toolbar, prompt: searchPrompt)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isNetworkScreen {
                    Picker("Show", selection: $state.filter) {
                        ForEach(DestinationFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if blocking.isHelperReady {
                    Label("Blocking on", systemImage: "shield.fill")
                        .labelStyle(BadgeLabelStyle(color: .hectorOK, iconSize: 9))
                        .help("The helper enforces your blocklist with pf, for every app on this Mac.")
                } else {
                    Label("Observe only", systemImage: "eye")
                        .labelStyle(BadgeLabelStyle(color: .secondary, iconSize: 9))
                        .help("Install the helper from Blocklists to block destinations.")
                }
                if isNetworkScreen {
                    Toggle(isOn: $monitor.isPaused) {
                        Label(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                    }
                    .help(monitor.isPaused ? "Resume live updates" : "Freeze the view")
                }
                Button {
                    state.showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the details panel")
            }
        }
        #if DEBUG
        .task {
            if DebugSnapshot.opensBlocklists { state.sidebarSelection = .blocklists }
            guard DebugSnapshot.hoverIndex != nil || DebugSnapshot.selectIndex != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            let rows = visibleRows.filter { $0.destination.country != nil }
            if let index = DebugSnapshot.hoverIndex, rows.indices.contains(index) { state.hovered = rows[index].id }
            if let index = DebugSnapshot.selectIndex, rows.indices.contains(index) { state.selectedDestination = rows[index].id }
        }
        #endif
        .sheet(isPresented: $state.showUninstall) { UninstallSheet() }
        .onChange(of: state.sidebarSelection) {
            if let selected = state.selectedDestination, let app = selectedAppID, selected.appID != app {
                state.selectedDestination = nil
            }
        }
        // Control tint: deeper than the sage ink in dark mode, so white labels stay readable.
        .tint(.hectorTint)
    }

    // MARK: - Map

    private func mapCard(rows: [DestinationRow]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            MapCardHeader(rows: rows)
            WorldMapView(
                rows: rows,
                focusAppID: selectedAppID,
                originCountry: monitor.originCountry,
                selected: state.selectedDestination,
                hovered: Bindable(state).hovered,
                onSelect: { row in
                    if selectedAppID != nil { state.sidebarSelection = .app(row.app.id) }
                    state.selectedDestination = row.id
                    state.showInspector = true
                }
            )
            .padding(Spacing.sm)
            .insetSurface(cornerRadius: Radius.lg)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.md)
        .canvasBackground()
    }

    // MARK: - Data

    private var searchPrompt: String {
        switch state.sidebarSelection {
        case .persistence: "Name, path, team ID"
        case .processes: "Name, PID, path, arguments"
        default: "Host, IP, country, port"
        }
    }

    private var title: String {
        switch state.sidebarSelection {
        case .blocklists: return "Blocklists"
        case .persistence: return "Persistence"
        case .processes: return "Processes"
        default: break
        }
        guard let id = selectedAppID else { return "All apps" }
        return monitor.apps[id]?.name ?? "Hector"
    }

    /// Every destination of every app that passes the filter and the search, for the map.
    private var visibleRows: [DestinationRow] {
        let query = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        let applied = blocking.applied
        return monitor.sortedApps.flatMap { app in
            app.sortedDestinations
                .filter { query.isEmpty || matches($0, app: app, query: query) }
                .map { DestinationRow(app: app, destination: $0,
                                      blockReason: applied.blockReason(for: $0.key.address, country: $0.country)) }
                .filter { state.filter.includes($0) }
        }
    }

    /// The list shows the selected app only, or every app.
    private func listGroups(from rows: [DestinationRow]) -> [DestinationGroup] {
        var order: [AppGroup.ID] = []
        var byApp: [AppGroup.ID: [DestinationRow]] = [:]
        for row in rows where selectedAppID == nil || row.app.id == selectedAppID {
            if byApp[row.app.id] == nil { order.append(row.app.id) }
            byApp[row.app.id, default: []].append(row)
        }
        return order.map { DestinationGroup(app: byApp[$0]![0].app, rows: byApp[$0]!) }
    }

    private func matches(_ destination: Destination, app: AppGroup, query: String) -> Bool {
        [destination.title, destination.key.address.description, String(destination.key.port),
         destination.country ?? "", Countries.name(destination.country), app.name]
            .contains { $0.lowercased().contains(query) }
    }

    private var selectedRow: DestinationRow? {
        guard let ref = state.selectedDestination, let app = monitor.apps[ref.appID],
              let destination = app.destinations[ref.key] else { return nil }
        return DestinationRow(app: app, destination: destination,
                              blockReason: blocking.applied.blockReason(for: destination.key.address, country: destination.country))
    }

    private var usedBySelected: [AppGroup] {
        guard let ref = state.selectedDestination else { return [] }
        return monitor.sortedApps.filter { app in app.destinations.keys.contains { $0.address == ref.key.address } }
    }
}

/// Title, counts and legend above the map. Drops the counts when the column is narrow.
private struct MapCardHeader: View {
    let rows: [DestinationRow]

    var body: some View {
        let countries = Set(rows.compactMap(\.destination.country)).count
        HStack(alignment: .center, spacing: Spacing.md) {
            // The Netbite module glyph: this is the network part of the app.
            NetbiteLogo(lineWidth: 2)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Destination map")
                    .font(.sectionTitle)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                Text("Hover a line to see which app owns it. Click it for details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.lg) {
                    Metric("\(rows.count)", label: rows.count == 1 ? "destination" : "destinations")
                    Metric("\(countries)", label: countries == 1 ? "country" : "countries")
                    Divider().frame(height: 30)
                    MapLegend()
                }
                MapLegend()
            }
            .layoutPriority(1)
        }
    }
}

private struct MapLegend: View {
    var body: some View {
        HStack(spacing: Spacing.md) {
            legend("Live") { path in
                path.stroke(Color.hectorOK, lineWidth: 2)
            }
            legend("Recent") { path in
                path.stroke(Color.hectorOK.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            legend("Blocked") { path in
                path.stroke(Color.hectorDanger, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            HStack(spacing: 5) {
                Circle().fill(.primary).frame(width: 7, height: 7)
                Text("You")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: solid lines are live, dashed lines are recent, red dashed lines are blocked, the dot is this Mac")
    }

    private func legend(_ title: String, stroke: @escaping (Path) -> some View) -> some View {
        HStack(spacing: 5) {
            stroke(Path { $0.move(to: CGPoint(x: 0, y: 3)); $0.addLine(to: CGPoint(x: 18, y: 3)) })
                .frame(width: 18, height: 6)
            Text(title)
        }
    }
}

/// Shown while the country database is missing, downloading or broken.
private struct GeoBanner: View {
    @Environment(ConnectionMonitor.self) private var monitor

    var body: some View {
        switch monitor.geoStatus {
        case .ready, .loading:
            EmptyView()
        case .missing:
            framed {
                Banner("Countries are not installed yet",
                       message: "The map needs the free DB-IP Lite database: about 25 MB, updated monthly, and every lookup stays on this Mac.",
                       kind: .info,
                       systemImage: "globe.badge.chevron.backward") {
                    Button("Download") { Task { await monitor.downloadGeo() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .downloading:
            framed {
                Banner("Downloading the country database…", kind: .info, systemImage: "arrow.down.circle") {
                    ProgressView().controlSize(.small)
                }
            }
        case .failed(let message):
            framed {
                Banner("The country database could not be loaded", message: message, kind: .warning) {
                    Button("Download Again") { Task { await monitor.downloadGeo() } }
                }
            }
        }
    }

    private func framed(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .frame(maxWidth: .infinity)
            .canvasBackground()
    }
}

private struct StatusBar: View {
    @Environment(ConnectionMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: Spacing.md) {
            HStack(spacing: 6) {
                StatusDot(kind: monitor.isPaused ? .neutral : .ok, pulsing: !monitor.isPaused, size: 7)
                Text(monitor.isPaused ? "Paused" : "Live · refreshed every second")
            }
            .help(monitor.isPaused ? "Updates are frozen. Resume from the toolbar." : "Connections are read with libproc every second.")
            separator
            Label(geoText, systemImage: "globe")
            if monitor.seesAllProcesses {
                separator
                Label("All processes, through the helper", systemImage: "checkmark.shield")
            } else if monitor.unreadableProcessCount > 0 {
                separator
                Label("\(monitor.unreadableProcessCount) processes of other users are hidden", systemImage: "eye.slash")
                    .help("System daemons belong to root. Install the helper (Blocklists) to see them.")
            }
            Spacer()
            Text("Hector \(HectorVersion.current)")
                .foregroundStyle(.tertiary)
        }
        .labelStyle(StatusBarLabelStyle())
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 6)
        .background(Color.surfaceCanvas)
    }

    private var separator: some View {
        Divider().frame(height: 10)
    }

    private var geoText: String {
        switch monitor.geoStatus {
        case .ready(let ranges): "GeoIP: DB-IP Lite, \(ranges.formatted()) ranges"
        case .loading: "GeoIP: loading…"
        case .downloading: "GeoIP: downloading…"
        case .missing: "GeoIP: not installed"
        case .failed: "GeoIP: error"
        }
    }
}

/// Small icon, tight spacing.
private struct StatusBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
