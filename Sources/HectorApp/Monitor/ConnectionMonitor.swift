import Foundation
import HectorCore
import Observation

/// Polls the socket collector once a second and keeps, per app, every destination seen this session.
@MainActor
@Observable
final class ConnectionMonitor {
    enum GeoStatus: Equatable {
        case loading
        case ready(ranges: Int)
        case missing
        case downloading
        case failed(String)
    }

    /// State of the optional network names (ASN) database.
    enum NetworkNamesStatus: Equatable {
        case loading
        case ready(networks: Int)
        case missing
        case downloading
        case failed(String)
    }

    static let historyLength = 60
    /// Destinations idle for longer than this leave the list.
    static let retention: TimeInterval = 30 * 60

    private(set) var apps: [AppGroup.ID: AppGroup] = [:]
    private(set) var unreadableProcessCount = 0
    private(set) var lastUpdate: Date?
    private(set) var geoStatus: GeoStatus = .loading
    private(set) var networkNamesStatus: NetworkNamesStatus = .loading
    /// Snapshots come from the root helper, so system daemons are included.
    private(set) var seesAllProcesses = false
    /// The helper is installed but did not answer the last snapshot in time: only the user's own
    /// processes are shown, and the screen says so.
    private(set) var helperDidNotAnswer = false
    var isPaused = false

    /// How often a snapshot is worth taking, set by the window. Every snapshot makes the helper
    /// walk every process's sockets as root, so it is never taken faster than someone looks.
    enum Demand: Equatable {
        /// The map and list are on screen: every second.
        case live
        /// Another screen is shown: the sidebar's counts only.
        case glance
        /// No window can be seen: just enough to keep recent destinations in the history.
        case hidden

        var interval: Duration {
            switch self {
            case .live: .seconds(1)
            case .glance: .seconds(5)
            case .hidden: .seconds(10)
            }
        }
    }

    @ObservationIgnored var demand = Demand.live
    @ObservationIgnored private var lastSnapshotAt = ContinuousClock.now - .seconds(3600)

    /// Where lines on the map start: the country the Mac is set to. No network lookup involved.
    let originCountry: String = {
        #if DEBUG
        if DemoData.isEnabled { return DemoData.originCountry }
        #endif
        return Locale.current.region?.identifier ?? "US"
    }()

    @ObservationIgnored private var geo: GeoIPDatabase?
    @ObservationIgnored private var networkNames: ASNDatabase?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var hostnames: [IPAddress: String] = [:]
    @ObservationIgnored private var lookedUp: Set<IPAddress> = []

    var sortedApps: [AppGroup] {
        apps.values.sorted {
            if ($0.liveCount > 0) != ($1.liveCount > 0) { return $0.liveCount > 0 }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var liveConnectionCount: Int { apps.values.reduce(0) { $0 + $1.liveCount } }

    func start() {
        guard loop == nil else { return }
        #if DEBUG
        if DemoData.isEnabled { return loadDemo() }
        #endif
        loop = Task { [weak self] in
            await self?.loadGeo()
            // Network names are secondary: they load in the background while snapshots start.
            Task { [weak self] in await self?.loadNetworkNames() }
            while !Task.isCancelled {
                guard let self else { return }
                // Wakes every second but takes a snapshot only when one is due: a window that
                // comes back into view is up to date within a second.
                if !self.isPaused, ContinuousClock.now - self.lastSnapshotAt >= self.demand.interval - .milliseconds(100) {
                    self.lastSnapshotAt = .now
                    let (snapshot, source) = await Task.detached(priority: .utility) { Self.takeSnapshot() }.value
                    if self.seesAllProcesses != (source == .helper) { self.seesAllProcesses = source == .helper }
                    if self.helperDidNotAnswer != (source == .helperFailed) { self.helperDidNotAnswer = source == .helperFailed }
                    self.ingest(snapshot)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    enum SnapshotSource { case helper, local, helperFailed }

    /// Asks the helper first (it runs as root and sees every process), then falls back to a local
    /// snapshot of the user's own processes. The timeout matches the Processes screen's: endpoint
    /// security agents can make walking every process's sockets slow, and a short timeout here
    /// dropped every root process (such an agent's own among them) from the map.
    nonisolated private static func takeSnapshot() -> (CollectorSnapshot, SnapshotSource) {
        guard HelperClient.isInstalled else { return (SocketCollector().snapshot(), .local) }
        if case .snapshot(let snapshot)? = try? HelperClient.send(.snapshot, timeout: 10) {
            return (snapshot, .helper)
        }
        return (SocketCollector().snapshot(), .helperFailed)
    }

    // MARK: - GeoIP

    func loadGeo() async {
        let url = GeoIPUpdater.defaultDatabaseURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            geoStatus = .missing
            return
        }
        geoStatus = .loading
        do {
            let database = try await Task.detached(priority: .userInitiated) { try GeoIPDatabase(contentsOf: url) }.value
            geo = database
            geoStatus = .ready(ranges: database.rangeCount)
            relabelCountries()
        } catch {
            geoStatus = .failed(String(describing: error))
        }
    }

    func downloadGeo() async {
        geoStatus = .downloading
        do {
            try await GeoIPUpdater.update()
            await loadGeo()
        } catch {
            geoStatus = .failed(String(describing: error))
        }
    }

    private func relabelCountries() {
        for id in apps.keys {
            for key in Array(apps[id]!.destinations.keys) {
                apps[id]!.destinations[key]!.country = geo?.country(for: key.address)
            }
        }
    }

    // MARK: - Network names (ASN)

    /// Loads the DB-IP ASN database if the user downloaded it. It is never downloaded on its own.
    func loadNetworkNames() async {
        let url = ASNUpdater.defaultDatabaseURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            networkNamesStatus = .missing
            return
        }
        networkNamesStatus = .loading
        do {
            let database = try await Task.detached(priority: .utility) { try ASNDatabase(contentsOf: url) }.value
            networkNames = database
            networkNamesStatus = .ready(networks: database.networkCount)
            relabelNetworks()
        } catch {
            networkNamesStatus = .failed(String(describing: error))
        }
    }

    func downloadNetworkNames() async {
        networkNamesStatus = .downloading
        do {
            try await ASNUpdater.update()
            await loadNetworkNames()
        } catch {
            networkNamesStatus = .failed(String(describing: error))
        }
    }

    private func relabelNetworks() {
        for id in apps.keys {
            for key in Array(apps[id]!.destinations.keys) {
                apps[id]!.destinations[key]!.network = networkNames?.owner(for: key.address)
            }
        }
    }

    // MARK: - Snapshots

    private func ingest(_ snapshot: CollectorSnapshot) {
        let now = snapshot.takenAt
        var seen: [AppGroup.ID: [DestinationKey: (count: Int, states: [String], ports: Set<String>)]] = [:]
        var pids: [AppGroup.ID: Set<Int32>] = [:]

        for entry in snapshot.processes {
            let process = entry.process
            let id = process.appBundleIdentifier ?? process.executablePath ?? process.name
            if apps[id] == nil {
                apps[id] = AppGroup(
                    id: id, name: process.displayName, bundleIdentifier: process.appBundleIdentifier,
                    bundlePath: process.appBundlePath, executablePath: process.executablePath,
                    kind: Self.kind(of: process), processNames: [], pids: [], destinations: [:], activity: []
                )
            }
            apps[id]!.processNames.insert(process.name)
            pids[id, default: []].insert(process.pid)
            // A CLOSED socket is a dead descriptor the app has not released yet, not traffic.
            for socket in entry.sockets where socket.hasRemote && socket.tcpState != "CLOSED" {
                let key = DestinationKey(address: socket.remoteAddress!)
                var info = seen[id, default: [:]][key] ?? (0, [], [])
                info.count += 1
                info.ports.insert(DestinationKey.portLabel(socket.remotePort, socket.transport))
                if let state = socket.tcpState { info.states.append(state) }
                seen[id, default: [:]][key] = info
            }
        }

        for id in Array(apps.keys) {
            var app = apps[id]!
            let current = seen[id] ?? [:]
            app.pids = pids[id] ?? []

            for (key, info) in current {
                if var destination = app.destinations[key] {
                    destination.liveConnections = info.count
                    destination.tcpStates = info.states
                    if !info.ports.isSubset(of: destination.ports) {
                        destination.ports = Array(info.ports.union(destination.ports)).sorted()
                    }
                    destination.lastSeen = now
                    app.destinations[key] = destination
                } else {
                    app.destinations[key] = Destination(
                        key: key, country: geo?.country(for: key.address), network: networkNames?.owner(for: key.address),
                        hostname: hostnames[key.address],
                        liveConnections: info.count, tcpStates: info.states, ports: info.ports.sorted(),
                        firstSeen: now, lastSeen: now, activity: []
                    )
                    resolveHostname(key.address)
                }
            }
            for key in Array(app.destinations.keys) {
                if current[key] == nil {
                    app.destinations[key]!.liveConnections = 0
                    app.destinations[key]!.tcpStates = []
                    if now.timeIntervalSince(app.destinations[key]!.lastSeen) > Self.retention {
                        app.destinations[key] = nil
                        continue
                    }
                }
                Self.record(app.destinations[key]!.liveConnections, into: &app.destinations[key]!.activity)
            }
            Self.record(app.liveCount, into: &app.activity)
            apps[id] = app.destinations.isEmpty ? nil : app
        }

        unreadableProcessCount = snapshot.unreadableProcessCount
        lastUpdate = now
    }

    private static func record(_ value: Int, into history: inout [Int]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    private static func kind(of process: NetProcess) -> AppKind {
        guard process.appBundlePath != nil, let path = process.executablePath, !path.hasPrefix("/System/") else {
            return .system
        }
        return .app
    }

    // MARK: - Reverse DNS

    private func resolveHostname(_ address: IPAddress) {
        guard !lookedUp.contains(address) else { return }
        lookedUp.insert(address)
        Task {
            guard let name = await Task.detached(priority: .background, operation: { ReverseDNS.lookup(address) }).value else { return }
            hostnames[address] = name
            for id in apps.keys {
                for key in apps[id]!.destinations.keys where key.address == address {
                    apps[id]!.destinations[key]!.hostname = name
                }
            }
        }
    }
}

#if DEBUG
extension ConnectionMonitor {
    /// `HECTOR_DEMO=1`: fixed sample connections instead of the Mac's own, and no snapshots.
    fileprivate func loadDemo() {
        apps = Dictionary(uniqueKeysWithValues: DemoData.connections().map { ($0.id, $0) })
        geoStatus = .ready(ranges: 618_402)
        networkNamesStatus = .ready(networks: 512_740)
        seesAllProcesses = true
        lastUpdate = DemoData.now
    }
}
#endif
