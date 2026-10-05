import AppKit
import Combine
import HectorCore
import SwiftUI

struct ContentView: View {
    @Environment(ConnectionMonitor.self) private var monitor
    @Environment(BlockingController.self) private var blocking
    @Environment(WindowState.self) private var state
    @Environment(SecurityController.self) private var security
    @Environment(PrivacyController.self) private var privacy
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    /// The network screens (map and list) as opposed to Blocklists and the security screens.
    private var isNetworkScreen: Bool {
        switch state.sidebarSelection {
        case .blocklists, .persistence, .processes, .checkup, .keyboardTaps, .captureDevices: false
        default: true
        }
    }

    private var selectedAppID: AppGroup.ID? { state.appFilter }

    /// Screens with a list to search and a details panel; the others hide both from the toolbar.
    private var hasSearchAndDetails: Bool {
        switch state.sidebarSelection {
        case .blocklists, .checkup, .captureDevices: false
        default: true
        }
    }

    /// Shows or hides the current screen's details panel.
    private func toggleDetails() {
        switch state.sidebarSelection {
        case .persistence: state.showPersistenceDetails.toggle()
        case .processes: state.showProcessDetails.toggle()
        case .keyboardTaps: state.showTapDetails.toggle()
        case .blocklists, .checkup, .captureDevices: break
        default: state.showInspector.toggle()
        }
    }

    var body: some View {
        @Bindable var monitor = monitor
        @Bindable var state = state
        let allCountryRows = visibleRows
        let rows = state.countryFilter.map { country in allCountryRows.filter { $0.destination.country == country } } ?? allCountryRows
        let groups = listGroups(from: rows)

        NavigationSplitView {
            SidebarView(selection: $state.sidebarSelection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            if state.sidebarSelection == .blocklists {
                BlocklistView()
            } else if state.sidebarSelection == .persistence {
                PersistenceView()
                    .searchable(text: $state.search, placement: .toolbar, prompt: searchPrompt)
            } else if state.sidebarSelection == .processes {
                ProcessesView()
                    .searchable(text: $state.search, placement: .toolbar, prompt: searchPrompt)
            } else if state.sidebarSelection == .checkup {
                CheckupView()
            } else if state.sidebarSelection == .keyboardTaps {
                KeyboardTapsView()
                    .searchable(text: $state.search, placement: .toolbar, prompt: searchPrompt)
            } else if state.sidebarSelection == .captureDevices {
                CaptureDevicesView()
            } else {
                VStack(spacing: 0) {
                    GeoBanner()
                    VSplitView {
                        // The map is width-bound (2.5:1); taller would only add empty bands.
                        mapCard(rows: rows, allCountryRows: allCountryRows)
                            .frame(minHeight: 160, idealHeight: 380, maxHeight: 480)
                        DestinationListView(groups: groups, selection: $state.selectedDestination, hovered: $state.hovered)
                            .frame(minHeight: 160)
                    }
                    Divider()
                    StatusBar()
                }
                .fillsSplitPane()
                .inspector(isPresented: $state.showInspector) {
                    DestinationDetailView(row: selectedRow, usedBy: usedBySelected)
                        .fillsSplitPane()
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
                .searchable(text: $state.search, placement: .toolbar, prompt: searchPrompt)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(isNetworkScreen ? "\(monitor.liveConnectionCount) live connections" : "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if isNetworkScreen {
                    AppFilterMenu(monitor: monitor, state: state)
                }
            }
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
                if hasSearchAndDetails {
                    Button {
                        toggleDetails()
                    } label: {
                        Label("Details", systemImage: "sidebar.trailing")
                    }
                    .help("Show or hide the details panel")
                }
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings: VirusTotal key, downloaded data, uninstall")
            }
        }
        #if DEBUG
        .task {
            if let screen = DebugSnapshot.screen { state.sidebarSelection = screen }
            if DemoData.isEnabled {
                state.selectedPersistenceItem = DemoData.selectedPersistenceItem
                state.selectedProcess = DemoData.selectedProcess
                // The sample tree is small: show it whole, and the details of the selected item.
                state.processesShowApple = true
            }
            if DebugSnapshot.opensSettings { openSettings() }
            if let country = DebugSnapshot.country {
                try? await Task.sleep(for: .seconds(4))
                state.countryFilter = country
            }
            if let country = DebugSnapshot.hoverCountry {
                try? await Task.sleep(for: .seconds(4))
                state.hoveredCountry = country
            }
            guard DebugSnapshot.hoverIndex != nil || DebugSnapshot.selectIndex != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            let rows = visibleRows.filter { $0.destination.country != nil }
            if let index = DebugSnapshot.hoverIndex, rows.indices.contains(index) { state.hovered = rows[index].id }
            if let index = DebugSnapshot.selectIndex, rows.indices.contains(index) { state.selectedDestination = rows[index].id }
        }
        #endif
        .sheet(isPresented: $state.showUninstall) { UninstallSheet() }
        // Snapshots only as often as someone can see them: see ConnectionMonitor.Demand.
        .onAppear(perform: updateDemand)
        .onChange(of: state.sidebarSelection) {
            updateDemand()
            state.search = ""
        }
        // A pick opens that screen's details panel.
        .onChange(of: state.selectedPersistenceItem) { if state.selectedPersistenceItem != nil { state.showPersistenceDetails = true } }
        .onChange(of: state.selectedProcess) { if state.selectedProcess != nil { state.showProcessDetails = true } }
        .onChange(of: privacy.selectedTap) { if privacy.selectedTap != nil { state.showTapDetails = true } }
        .onChange(of: state.selectedDestination) { if state.selectedDestination != nil { state.showInspector = true } }
        // Closed while Hector stays in the menu bar: back to the slow pace at once.
        .onDisappear { monitor.demand = .hidden }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in updateDemand() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in updateDemand() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in updateDemand() }
        .onChange(of: state.appFilter) {
            if let selected = state.selectedDestination, let app = selectedAppID, selected.appID != app {
                state.selectedDestination = nil
            }
        }
        // Control tint: deeper than the sage ink in dark mode, so white labels stay readable.
        .tint(.hectorTint)
    }

    private func updateDemand() {
        let visible = !NSApp.isHidden && NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && $0.contentViewController != nil
        }
        monitor.demand = !visible ? .hidden : (isNetworkScreen ? .live : .glance)
    }

    // MARK: - Map

    private func mapCard(rows: [DestinationRow], allCountryRows: [DestinationRow]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            MapCardHeader(rows: rows, allCountryRows: allCountryRows, state: state)
            WorldMapView(
                rows: rows,
                focusAppID: selectedAppID,
                originCountry: monitor.originCountry,
                state: state,
                onSelect: { row in
                    if selectedAppID != nil { state.appFilter = row.app.id }
                    state.selectedDestination = row.id
                    state.showInspector = true
                }
            )
            .padding(Spacing.sm)
            .insetSurface(cornerRadius: Radius.lg)
            // Hector peeks over the bottom edge of the map, in the South Pacific, watching the lines.
            .overlay(alignment: .bottomLeading) {
                HectorPeek(gaze: .right)
                    .frame(width: 34)
                    .padding(.leading, Spacing.xl)
                    .allowsHitTesting(false)
            }
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
        case .keyboardTaps: "App, PID, path"
        default: "Host, IP, country, network, port"
        }
    }

    private var title: String {
        switch state.sidebarSelection {
        case .blocklists: return "Blocklists"
        case .persistence: return "Persistence"
        case .processes: return "Processes"
        case .checkup: return "Checkup"
        case .keyboardTaps: return "Keyboard taps"
        case .captureDevices: return "Camera & mic"
        default: break
        }
        guard let id = selectedAppID else { return "Connections" }
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
        let network: String = destination.network?.label ?? ""
        let fields: [String] = [destination.title, destination.key.address.description, destination.portsLabel,
                                destination.country ?? "", Countries.name(destination.country), network, app.name]
        return fields.contains { $0.lowercased().contains(query) }
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
///
/// The country count is also the country filter: it lists every country with its destinations.
private struct MapCardHeader: View {
    let rows: [DestinationRow]
    /// The rows before the country filter, for the list of countries.
    let allCountryRows: [DestinationRow]
    let state: WindowState

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            // The Netbite module glyph: this is the network part of the app.
            NetbiteLogo(lineWidth: 2)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.sm) {
                    Text("Destination map")
                        .font(.sectionTitle)
                        .fixedSize()
                        .accessibilityAddTraits(.isHeader)
                    if let country = state.countryFilter {
                        CountryFilterChip(country: country) { state.countryFilter = nil }
                    }
                }
                Text(state.countryFilter == nil
                     ? "Hover a line to see which apps use it. Click a country to show only it."
                     : "Hover a line to see which app owns it. Click it for details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.lg) {
                    Metric("\(rows.count)", label: rows.count == 1 ? "destination" : "destinations")
                    countryMenu
                    Divider().frame(height: 30)
                    MapLegend()
                }
                HStack(spacing: Spacing.lg) {
                    countryMenu
                    MapLegend()
                }
                MapLegend()
            }
            .layoutPriority(1)
        }
    }

    /// Countries by number of destinations, most first.
    private var countries: [(code: String, count: Int)] {
        var counts: [String: Int] = [:]
        for row in allCountryRows { if let country = row.destination.country { counts[country, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
    }

    private var countryMenu: some View {
        let countries = self.countries
        return Menu {
            Button {
                state.countryFilter = nil
            } label: {
                if state.countryFilter == nil { Label("All countries", systemImage: "checkmark") } else { Text("All countries") }
            }
            Divider()
            ForEach(countries, id: \.code) { entry in
                Button {
                    state.countryFilter = entry.code
                } label: {
                    let title = "\(Countries.name(entry.code)) · \(entry.count)"
                    if state.countryFilter == entry.code { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Metric("\(countries.count)", label: countries.count == 1 ? "country" : "countries")
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only one country")
        .disabled(countries.isEmpty)
    }
}

/// The country the screen is narrowed to, with a button to show every country again.
private struct CountryFilterChip: View {
    let country: String
    let clear: () -> Void

    var body: some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Text(country).font(.caption2.weight(.bold).monospaced())
                Text(Countries.name(country)).font(.caption.weight(.semibold)).lineLimit(1)
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color.hectorOK)
            .background(Color.hectorOKWash, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Show every country")
        .accessibilityLabel("Only \(Countries.name(country)). Show every country")
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
                StatusDot(kind: monitor.isPaused ? .neutral : .ok, size: 7)
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
        case .ready(let ranges): "GeoIP: DB-IP Lite, \(Display.count(ranges)) ranges"
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

/// Narrows the Connections screen to one app. Replaces the per-app rows the sidebar used to
/// have. Takes its models as parameters: toolbar items are hosted outside the window's view tree.
private struct AppFilterMenu: View {
    let monitor: ConnectionMonitor
    let state: WindowState

    var body: some View {
        let apps = monitor.apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Menu {
            Button("All apps") { state.appFilter = nil }
            Divider()
            Section("Apps") {
                ForEach(apps.filter { $0.kind == .app }) { app in
                    Button(label(for: app)) { state.appFilter = app.id }
                }
            }
            Section("System & tools") {
                ForEach(apps.filter { $0.kind == .system }) { app in
                    Button(label(for: app)) { state.appFilter = app.id }
                }
            }
        } label: {
            Label(currentName, systemImage: state.appFilter == nil ? "square.grid.2x2" : "app.badge.checkmark")
        }
        .help("Show the connections of every app, or of one app")
    }

    private var currentName: String {
        guard let id = state.appFilter else { return "All apps" }
        return monitor.apps[id]?.name ?? "All apps"
    }

    private func label(for app: AppGroup) -> String {
        app.liveCount > 0 ? "\(app.name) · \(app.liveCount) live" : app.name
    }
}
