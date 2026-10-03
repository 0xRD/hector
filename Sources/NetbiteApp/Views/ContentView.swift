import NetbiteCore
import SwiftUI

struct ContentView: View {
    @Environment(ConnectionMonitor.self) private var monitor

    @Environment(WindowState.self) private var state

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
        .navigationTitle(title)
        .navigationSubtitle("\(monitor.liveConnectionCount) live connections")
        .searchable(text: $state.search, placement: .toolbar, prompt: "Host, IP, country, port")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $state.filter) {
                    ForEach(DestinationFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Label("Observe mode", systemImage: "eye")
                    .labelStyle(BadgeLabelStyle(color: .netbiteAccent))
                    .help("Netbite watches every app. Blocking arrives in 0.3 and will apply to the whole Mac.")
                Toggle(isOn: $monitor.isPaused) {
                    Label(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .help(monitor.isPaused ? "Resume live updates" : "Freeze the view")
                Button {
                    state.showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide destination details")
            }
        }
        #if DEBUG
        .task {
            guard DebugSnapshot.hoverIndex != nil || DebugSnapshot.selectIndex != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            let rows = visibleRows.filter { $0.destination.country != nil }
            if let index = DebugSnapshot.hoverIndex, rows.indices.contains(index) { state.hovered = rows[index].id }
            if let index = DebugSnapshot.selectIndex, rows.indices.contains(index) { state.selectedDestination = rows[index].id }
        }
        #endif
        .onChange(of: state.sidebarSelection) {
            if let selected = state.selectedDestination, let app = selectedAppID, selected.appID != app {
                state.selectedDestination = nil
            }
        }
    }

    // MARK: - Map

    private func mapCard(rows: [DestinationRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Destination map").font(.headline)
                    let countries = Set(rows.compactMap(\.destination.country)).count
                    Text("\(rows.count) destinations · \(countries) countries · hover a line to see which app owns it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MapLegend()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
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
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(.background.secondary)
    }

    // MARK: - Data

    private var title: String {
        guard let id = selectedAppID else { return "All apps" }
        return monitor.apps[id]?.name ?? "Netbite"
    }

    /// Every destination of every app that passes the filter and the search, for the map.
    private var visibleRows: [DestinationRow] {
        let query = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        return monitor.sortedApps.flatMap { app in
            app.sortedDestinations
                .filter { state.filter.includes($0) && (query.isEmpty || matches($0, app: app, query: query)) }
                .map { DestinationRow(app: app, destination: $0) }
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
        return DestinationRow(app: app, destination: destination)
    }

    private var usedBySelected: [AppGroup] {
        guard let ref = state.selectedDestination else { return [] }
        return monitor.sortedApps.filter { app in app.destinations.keys.contains { $0.address == ref.key.address } }
    }
}

private struct MapLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            legend("Live") { path in
                path.stroke(Color.netbiteAccent, lineWidth: 2)
            }
            legend("Recent") { path in
                path.stroke(Color.netbiteAccent.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            HStack(spacing: 5) {
                Circle().fill(.primary).frame(width: 8, height: 8)
                Text("You")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legend(_ title: String, stroke: @escaping (Path) -> some View) -> some View {
        HStack(spacing: 5) {
            stroke(Path { $0.move(to: CGPoint(x: 0, y: 3)); $0.addLine(to: CGPoint(x: 20, y: 3)) })
                .frame(width: 20, height: 6)
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
            banner("Countries need the free DB-IP Lite database (about 25 MB, updated monthly).", button: "Download")
        case .downloading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Downloading the country database…")
                Spacer()
            }
            .padding(10)
            .background(.yellow.opacity(0.12))
        case .failed(let message):
            banner("The country database could not be loaded: \(message)", button: "Download again")
        }
    }

    private func banner(_ text: String, button: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "globe.badge.chevron.backward")
            Text(text).lineLimit(2)
            Spacer()
            Button(button) { Task { await monitor.downloadGeo() } }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}

private struct StatusBar: View {
    @Environment(ConnectionMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.isPaused ? Color.secondary : Color.netbiteAccent)
                    .frame(width: 7, height: 7)
                Text(monitor.isPaused ? "Paused" : "Live · libproc every 1 s")
            }
            Text(geoText)
            if monitor.unreadableProcessCount > 0 {
                Text("\(monitor.unreadableProcessCount) processes of other users are not visible yet")
                    .help("System daemons belong to root. The privileged helper (0.3) will report them.")
            }
            Spacer()
            Text("Netbite 0.2 · observe only")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
