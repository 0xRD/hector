import Foundation
import HectorCore

/// Applies a blocklist to pf and /etc/hosts, and undoes it.
///
/// In dry-run mode every path lives under a scratch root and commands are logged, not run, so the
/// whole flow can be exercised without root.
final class Enforcer {
    struct State: Codable {
        /// Reference from `pfctl -E`, released with `pfctl -X` so we never disable pf for others.
        var pfToken: String?
        var appliedAt: Date?
    }

    let dryRun: Bool
    let dataDirectory: URL
    let hostsFile: URL
    private var pfDirectory: URL { dataDirectory.appending(path: "pf", directoryHint: .isDirectory) }
    private var blocklistFile: URL { dataDirectory.appending(path: "blocklist.json") }
    private var stateFile: URL { dataDirectory.appending(path: "state.json") }
    private var geoFile: URL { dataDirectory.appending(path: "dbip-country-lite.csv") }
    /// Validated copies of the hosts lists, one domain per line, and what is known about them.
    private var listsDirectory: URL { dataDirectory.appending(path: "lists", directoryHint: .isDirectory) }
    private var listStatesFile: URL { listsDirectory.appending(path: "state.json") }

    private var lastCompiled: CompiledBlocklist?
    /// Parsed lists, by identifier, so an apply does not read and validate them again.
    private var listCache: [String: [String]] = [:]
    private var listStates: [String: HostsListState] = [:]
    /// The first scheduled check waits a while after launch: at boot the network may not be up.
    private var nextListCheck = Date().addingTimeInterval(HostsListCatalog.checkInterval)
    private var backgroundFetch: BackgroundFetch?

    init(root: URL?) throws {
        dryRun = root != nil
        let base = root ?? URL(fileURLWithPath: "/")
        dataDirectory = base.appending(path: String(HelperPaths.dataDirectory.dropFirst()), directoryHint: .isDirectory)
        hostsFile = base.appending(path: "etc/hosts")
        if dryRun {
            try FileManager.default.createDirectory(at: pfDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: listsDirectory, withIntermediateDirectories: true)
        } else {
            // Root-only: the applied blocklist is private and nobody else may plant files here.
            try SecureFiles.ensureDirectory(dataDirectory.path, mode: 0o700)
            try SecureFiles.ensureDirectory(pfDirectory.path, mode: 0o700)
            try SecureFiles.ensureDirectory(listsDirectory.path, mode: 0o700)
        }
        listStates = loadListStates()
        if dryRun, !FileManager.default.fileExists(atPath: hostsFile.path) {
            try FileManager.default.createDirectory(at: hostsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/etc/hosts", toPath: hostsFile.path)
        }
    }

    // MARK: - Commands

    /// Re-applies the stored blocklist: pf rules do not survive a reboot. Hosts lists come from
    /// their copies on disk; nothing is downloaded at boot.
    func restoreAtLaunch() {
        guard let blocklist = try? Blocklist.load(from: blocklistFile) else { return }
        do {
            _ = try apply(blocklist, downloadMissingLists: false)
            log("Restored the blocklist at launch.")
        } catch {
            log("Could not restore the blocklist at launch: \(error)")
        }
    }

    /// `downloadMissingLists`: download subscribed lists that have no copy yet (an apply from the
    /// user); a failed download is reported in the list's state and the rest is applied.
    func apply(_ blocklist: Blocklist, downloadMissingLists: Bool = true) throws -> HelperStatus {
        let geo = blocklist.blockedCountries.isEmpty ? nil : try loadGeo()
        let lists = availableLists(blocklist.hostsLists, downloadMissing: downloadMissingLists)
        let compiled = RuleCompiler.compile(blocklist, geo: geo, lists: lists)
        let networks = compiled.blockTable.count + compiled.geoTable.count
        guard networks <= HelperLimits.maximumPFNetworks else {
            // Refused before anything changes: the rules in force stay as they are.
            throw CommandError(description: "These rules need \(networks.formatted()) networks; Hector allows up to "
                + "\(HelperLimits.maximumPFNetworks.formatted()) (pf's system-wide limit is about \(200_000.formatted())). "
                + "Large countries such as the United States have more than \(250_000.formatted()) networks on their own.")
        }
        let ruleset = pfDirectory.appending(path: "netbite.pf.conf")
        let files: [(URL, String)] = [
            (ruleset, PFAnchor.ruleset(tableDirectory: pfDirectory.path)),
            (pfDirectory.appending(path: "\(PFAnchor.blockTable).table"), PFAnchor.tableFile(compiled.blockTable)),
            (pfDirectory.appending(path: "\(PFAnchor.geoTable).table"), PFAnchor.tableFile(compiled.geoTable)),
        ]

        // Keep the previous files so a pfctl failure leaves the last good ruleset in place.
        let previous = files.map { (url, _) in (url, try? Data(contentsOf: url)) }
        for (url, contents) in files { try writeFile(Data(contents.utf8), to: url, mode: 0o600) }
        do {
            try ensureMainRulesetEvaluatesAnchors()
            try run("/sbin/pfctl", "-a", PFAnchor.name, "-f", ruleset.path)
        } catch {
            for (url, data) in previous { if let data { try? writeFile(data, to: url, mode: 0o600) } }
            _ = try? run("/sbin/pfctl", "-a", PFAnchor.name, "-f", ruleset.path)
            throw error
        }

        var state = loadState()
        try enablePF(&state)
        try writeHosts(domains: compiled.hostsDomains, listDomains: compiled.listDomains)
        state.appliedAt = Date()
        try saveState(state)
        try writeFile(JSONEncoder.hector.encode(blocklist), to: blocklistFile, mode: 0o600)
        lastCompiled = compiled
        log("Applied: \(compiled.blockTable.count) networks, \(compiled.geoTable.count) country networks, \(compiled.hostsDomains.count) domains, \(compiled.listDomains.count) list domains.")
        return status()
    }

    func flush() throws -> HelperStatus {
        _ = try? run("/sbin/pfctl", "-a", PFAnchor.name, "-F", "all")
        var state = loadState()
        if let token = state.pfToken {
            _ = try? run("/sbin/pfctl", "-X", token)
            state.pfToken = nil
        }
        try writeHosts(domains: [], listDomains: [])
        state.appliedAt = nil
        try saveState(state)
        try? FileManager.default.removeItem(at: blocklistFile)
        lastCompiled = nil
        log("Flushed every Hector rule.")
        return status()
    }

    func status() -> HelperStatus {
        let blocklist = try? Blocklist.load(from: blocklistFile)
        if lastCompiled == nil, let blocklist {
            let geo = blocklist.blockedCountries.isEmpty ? nil : try? loadGeo(download: false)
            let lists = availableLists(blocklist.hostsLists, downloadMissing: false)
            lastCompiled = RuleCompiler.compile(blocklist, geo: geo, lists: lists)
        }
        // stdout only: pfctl prints warnings such as "No ALTQ support in kernel" on stderr, which
        // would otherwise make an empty anchor look loaded.
        let info = dryRun ? "" : ((try? run("/sbin/pfctl", "-s", "info", stdoutOnly: true)) ?? "")
        let anchorRules = dryRun ? "" : ((try? run("/sbin/pfctl", "-a", PFAnchor.name, "-s", "rules", stdoutOnly: true)) ?? "")
        return HelperStatus(
            version: HectorVersion.current,
            pfEnabled: info.contains("Status: Enabled"),
            anchorLoaded: !anchorRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            appliedAt: loadState().appliedAt,
            blocklist: blocklist,
            blockTableCount: lastCompiled?.blockTable.count ?? 0,
            geoTableCount: lastCompiled?.geoTable.count ?? 0,
            hostsDomainCount: lastCompiled?.hostsDomains.count ?? 0,
            warnings: lastCompiled?.warnings ?? [],
            listDomainCount: lastCompiled?.listDomains.count ?? 0,
            hostsLists: listStatus(subscribed: blocklist?.hostsLists ?? [])
        )
    }

    // MARK: - Hosts lists

    /// Downloads every list of the enforced blocklist now (conditionally), and applies again if one
    /// changed. The request carries no list: only the catalog's fixed URLs are ever fetched.
    func refreshHostsLists() throws -> HelperStatus {
        guard let blocklist = try? Blocklist.load(from: blocklistFile), !blocklist.hostsLists.isEmpty else { return status() }
        var changed = false
        for id in blocklist.hostsLists.sorted() {
            guard let source = HostsListCatalog.source(id) else { continue }
            if update(source) { changed = true }
        }
        if changed { _ = try apply(blocklist, downloadMissingLists: false) }
        return status()
    }

    /// Whether a scheduled download runs in the background; the server loop then wakes up often
    /// to collect it.
    var isRefreshingInBackground: Bool { backgroundFetch != nil }

    /// Called by the server loop between requests and when it wakes up. Scheduled downloads (lists
    /// due weekly, or `retryInterval` after a failure) run in the background so the helper keeps
    /// answering; their results are recorded and applied here, on the loop's thread. Cheap when
    /// nothing is due.
    func refreshHostsListsIfDue(now: Date = Date()) {
        if let fetch = backgroundFetch {
            guard let results = fetch.results() else { return }
            backgroundFetch = nil
            var changed = false
            for (source, result) in results {
                if record(result, for: source, at: fetch.startedAt) { changed = true }
            }
            // Read again: the blocklist may have been changed or flushed meanwhile.
            guard changed, let blocklist = try? Blocklist.load(from: blocklistFile) else { return }
            do {
                _ = try apply(blocklist, downloadMissingLists: false)
                log("Applied the updated hosts lists.")
            } catch {
                log("Could not apply the updated hosts lists: \(error)")
            }
            return
        }

        guard now >= nextListCheck else { return }
        nextListCheck = now.addingTimeInterval(HostsListCatalog.checkInterval)
        guard let blocklist = try? Blocklist.load(from: blocklistFile), !blocklist.hostsLists.isEmpty else { return }
        var requests: [BackgroundFetch.Request] = []
        for id in blocklist.hostsLists.sorted() {
            guard let source = HostsListCatalog.source(id) else { continue }
            let state = listStates[id] ?? HostsListState(id: id)
            guard state.isDue(at: now) else { continue }
            let hasCopy = cachedList(id) != nil
            requests.append(BackgroundFetch.Request(source: source, etag: hasCopy ? state.etag : nil,
                                                    lastModified: hasCopy ? state.lastModified : nil))
        }
        guard !requests.isEmpty else { return }
        log("Checking \(requests.count) hosts list(s) for updates in the background.")
        let fetch = BackgroundFetch(startedAt: now)
        backgroundFetch = fetch
        let pending: [BackgroundFetch.Request] = requests
        // A plain queue, not a task: each download blocks while its unprivileged child runs.
        DispatchQueue.global(qos: .utility).async {
            for request in pending {
                do {
                    let outcome = try Unprivileged.hostsList(request.source, etag: request.etag, lastModified: request.lastModified)
                    fetch.add(request.source, .success(outcome))
                } catch {
                    fetch.add(request.source, .failure(error))
                }
            }
            fetch.finish()
        }
    }

    /// The parsed domains of each subscribed list that has a copy, downloading missing ones when
    /// asked. Lists no longer subscribed leave the memory cache.
    private func availableLists(_ subscribed: Set<String>, downloadMissing: Bool) -> [String: [String]] {
        listCache = listCache.filter { subscribed.contains($0.key) }
        var lists: [String: [String]] = [:]
        for id in subscribed.sorted() {
            guard let source = HostsListCatalog.source(id) else { continue }
            if let domains = cachedList(id) {
                lists[id] = domains
            } else if downloadMissing, update(source), let domains = cachedList(id) {
                lists[id] = domains
            }
        }
        return lists
    }

    /// The copy on disk, validated again with the same parser (it is root-only, but this costs
    /// little and a damaged file must not reach /etc/hosts).
    private func cachedList(_ id: String) -> [String]? {
        if let domains = listCache[id] { return domains }
        let url = listFile(id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= HostsListCatalog.maximumDownloadSize,
              let data = try? Data(contentsOf: url) else { return nil }
        let domains = HostsListParser.parse(data).domains
        listCache[id] = domains
        return domains
    }

    /// `id` comes from the catalog (checked by every caller), so it is a safe file name.
    private func listFile(_ id: String) -> URL {
        listsDirectory.appending(path: "\(id).txt")
    }

    /// Downloads one list and waits for it (a request from the user). Returns `true` when a new
    /// copy replaced the old one.
    private func update(_ source: HostsListSource) -> Bool {
        let state = listStates[source.id] ?? HostsListState(id: source.id)
        let now = Date()
        // Validators only make sense when the copy they describe is still here.
        let hasCopy = cachedList(source.id) != nil
        log("Downloading the hosts list \(source.name)…")
        let etag: String? = hasCopy ? state.etag : nil
        let lastModified: String? = hasCopy ? state.lastModified : nil
        let result: Result<HostsListDownloader.Outcome, any Error> = Result { try fetch(source, etag: etag, lastModified: lastModified) }
        return record(result, for: source, at: now)
    }

    /// Records the outcome of a download attempt made at `now`: a new copy is written and kept in
    /// memory; on any failure the last good copy stays and the error goes into the list's state.
    /// Returns `true` when a new copy replaced the old one.
    private func record(_ result: Result<HostsListDownloader.Outcome, any Error>, for source: HostsListSource, at now: Date) -> Bool {
        var state = listStates[source.id] ?? HostsListState(id: source.id)
        state.attemptedAt = now
        var changed = false
        do {
            switch try result.get() {
            case .notModified:
                log("\(source.name) has not changed.")
            case .downloaded(let parsed, let etag, let lastModified):
                let body = parsed.domains.joined(separator: "\n") + "\n"
                try writeFile(Data(body.utf8), to: listFile(source.id), mode: 0o600)
                listCache[source.id] = parsed.domains
                state.domainCount = parsed.domains.count
                state.invalidLines = parsed.invalidLines
                state.skippedEntries = parsed.skippedEntries
                state.updatedAt = now
                state.etag = etag
                state.lastModified = lastModified
                changed = true
                log("\(source.name): \(parsed.domains.count) domains, \(parsed.invalidLines) invalid lines, \(parsed.skippedEntries) entries skipped.")
            }
            state.checkedAt = now
            state.lastError = nil
        } catch {
            let message = (error as? HostsListDownloader.DownloadError)?.description ?? error.localizedDescription
            state.lastError = String(message.prefix(300))
            log("Could not update the hosts list \(source.name): \(message)")
        }
        listStates[source.id] = state
        saveListStates()
        return changed
    }

    /// Waits for the download, made by an unprivileged child (see `Unprivileged`); its time
    /// limit bounds the wait.
    private func fetch(_ source: HostsListSource, etag: String?, lastModified: String?) throws -> HostsListDownloader.Outcome {
        try Unprivileged.hostsList(source, etag: etag, lastModified: lastModified)
    }

    /// The state of every catalog list that is subscribed or has been downloaded, catalog order.
    private func listStatus(subscribed: Set<String>) -> [HostsListState] {
        HostsListCatalog.all.compactMap { (source: HostsListSource) -> HostsListState? in
            if let state = listStates[source.id] { return state }
            return subscribed.contains(source.id) ? HostsListState(id: source.id) : nil
        }
    }

    private func loadListStates() -> [String: HostsListState] {
        guard let data = try? Data(contentsOf: listStatesFile),
              let states = try? JSONDecoder.hector.decode([HostsListState].self, from: data) else { return [:] }
        var byID: [String: HostsListState] = [:]
        for state in states where HostsListCatalog.source(state.id) != nil {
            byID[state.id] = state
        }
        return byID
    }

    private func saveListStates() {
        let states = listStates.values.sorted { $0.id < $1.id }
        do {
            try writeFile(JSONEncoder.hector.encode(states), to: listStatesFile, mode: 0o600)
        } catch {
            log("Could not save the hosts lists state: \(error)")
        }
    }

    // MARK: - pf

    /// Our sub-anchor is only evaluated if the main ruleset contains `anchor "com.apple/*"`, which the
    /// stock /etc/pf.conf provides. If pf has no main ruleset at all, load the stock one.
    private func ensureMainRulesetEvaluatesAnchors() throws {
        guard !dryRun else { return }
        let main = try run("/sbin/pfctl", "-s", "rules", stdoutOnly: true)
        if main.contains("anchor \"com.apple/*\"") { return }
        if main.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try run("/sbin/pfctl", "-f", "/etc/pf.conf")
        } else {
            log("warning: the main pf ruleset has no anchor \"com.apple/*\"; Netbite's rules may not be evaluated.")
        }
    }

    /// Takes our own reference on pf. After a reboot the stored token is stale and pf is disabled,
    /// so a new one is taken.
    private func enablePF(_ state: inout State) throws {
        let enabled = !dryRun && ((try? run("/sbin/pfctl", "-s", "info", stdoutOnly: true)) ?? "").contains("Status: Enabled")
        if state.pfToken != nil && enabled { return }
        let output = try run("/sbin/pfctl", "-E")
        if let line = output.split(separator: "\n").first(where: { $0.contains("Token") }),
           let token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
            state.pfToken = token
        }
    }

    // MARK: - /etc/hosts

    private func writeHosts(domains: [String], listDomains: [String]) throws {
        let current = (try? String(contentsOf: hostsFile, encoding: .utf8)) ?? ""
        let updated = HostsFile.render(existing: current, domains: domains, listDomains: listDomains)
        guard updated != current else { return }
        // /etc/hosts must stay world-readable: every process resolves names through it.
        try writeFile(Data(updated.utf8), to: hostsFile, mode: 0o644)
        _ = try? run("/usr/bin/dscacheutil", "-flushcache")
        _ = try? run("/usr/bin/killall", "-HUP", "mDNSResponder")
    }

    // MARK: - GeoIP

    private func loadGeo(download: Bool = true) throws -> GeoIPDatabase {
        if !FileManager.default.fileExists(atPath: geoFile.path) {
            guard download else { throw CocoaError(.fileNoSuchFile) }
            log("Downloading the DB-IP country database…")
            // Downloaded, decompressed and checked by an unprivileged child; parsed again below.
            try writeFile(try Unprivileged.countriesCSV(), to: geoFile, mode: 0o644)
        }
        return try GeoIPDatabase(contentsOf: geoFile)
    }

    // MARK: - Plumbing

    private func loadState() -> State {
        (try? JSONDecoder.hector.decode(State.self, from: Data(contentsOf: stateFile))) ?? State()
    }

    private func saveState(_ state: State) throws {
        try writeFile(JSONEncoder.hector.encode(state), to: stateFile, mode: 0o600)
    }

    private func writeFile(_ data: Data, to url: URL, mode: mode_t) throws {
        // A dry run too: Foundation's atomic write goes through a temporary folder elsewhere,
        // which the sandbox refuses.
        try SecureFiles.write(data, to: url.path, mode: mode)
    }

    struct CommandError: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs a fixed executable with separate arguments (never through a shell). Returns stdout,
    /// plus stderr unless `stdoutOnly`; errors always include both.
    @discardableResult
    private func run(_ executable: String, _ arguments: String..., stdoutOnly: Bool = false) throws -> String {
        if dryRun {
            log("[dry-run] \(([executable] + arguments).joined(separator: " "))")
            return executable == "/sbin/pfctl" && arguments == ["-E"] ? "Token : 1234567890\n" : ""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A fixed environment, whatever the helper was started with.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read stderr concurrently so a chatty command cannot fill one pipe and block.
        let errorData = ErrorBuffer()
        let reader = Thread { errorData.data = err.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        while !reader.isFinished { usleep(1_000) }
        let stderr = String(decoding: errorData.data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandError(description: "\(([executable] + arguments).joined(separator: " ")) failed: \((stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return stdoutOnly ? stdout : stdout + stderr
    }
}

private final class ErrorBuffer: @unchecked Sendable {
    var data = Data()
}

/// Scheduled downloads running in the background. The task only downloads and parses; the
/// helper's state and files are changed by the server loop once `results()` returns them.
final class BackgroundFetch: @unchecked Sendable {
    struct Request: Sendable {
        let source: HostsListSource
        let etag: String?
        let lastModified: String?
    }

    let startedAt: Date
    private let lock = NSLock()
    private var collected: [(HostsListSource, Result<HostsListDownloader.Outcome, any Error>)] = []
    private var finished = false

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    func add(_ source: HostsListSource, _ result: Result<HostsListDownloader.Outcome, any Error>) {
        lock.withLock { collected.append((source, result)) }
    }

    func finish() {
        lock.withLock { finished = true }
    }

    /// Every result once the task is done, `nil` while it runs.
    func results() -> [(HostsListSource, Result<HostsListDownloader.Outcome, any Error>)]? {
        lock.withLock { finished ? collected : nil }
    }
}

/// Every log line goes through `LogText.sanitized`: messages can carry text sent by a client.
func log(_ message: String) {
    let line = "\(Date().formatted(.iso8601)) \(LogText.sanitized(message))\n"
    FileHandle.standardError.write(Data(line.utf8))
}
