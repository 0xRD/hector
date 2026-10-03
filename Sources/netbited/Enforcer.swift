import Foundation
import NetbiteCore

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

    private var lastCompiled: CompiledBlocklist?

    init(root: URL?) throws {
        dryRun = root != nil
        let base = root ?? URL(fileURLWithPath: "/")
        dataDirectory = base.appending(path: String(HelperPaths.dataDirectory.dropFirst()), directoryHint: .isDirectory)
        hostsFile = base.appending(path: "etc/hosts")
        if dryRun {
            try FileManager.default.createDirectory(at: pfDirectory, withIntermediateDirectories: true)
        } else {
            // Root-only: the applied blocklist is private and nobody else may plant files here.
            try SecureFiles.ensureDirectory(dataDirectory.path, mode: 0o700)
            try SecureFiles.ensureDirectory(pfDirectory.path, mode: 0o700)
        }
        if dryRun, !FileManager.default.fileExists(atPath: hostsFile.path) {
            try FileManager.default.createDirectory(at: hostsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/etc/hosts", toPath: hostsFile.path)
        }
    }

    // MARK: - Commands

    /// Re-applies the stored blocklist: pf rules do not survive a reboot.
    func restoreAtLaunch() {
        guard let blocklist = try? Blocklist.load(from: blocklistFile) else { return }
        do {
            _ = try apply(blocklist)
            log("Restored the blocklist at launch.")
        } catch {
            log("Could not restore the blocklist at launch: \(error)")
        }
    }

    func apply(_ blocklist: Blocklist) throws -> HelperStatus {
        let geo = blocklist.blockedCountries.isEmpty ? nil : try loadGeo()
        let compiled = RuleCompiler.compile(blocklist, geo: geo)
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
        try writeHosts(domains: compiled.hostsDomains)
        state.appliedAt = Date()
        try saveState(state)
        try writeFile(JSONEncoder.netbite.encode(blocklist), to: blocklistFile, mode: 0o600)
        lastCompiled = compiled
        log("Applied: \(compiled.blockTable.count) networks, \(compiled.geoTable.count) country networks, \(compiled.hostsDomains.count) domains.")
        return status()
    }

    func flush() throws -> HelperStatus {
        _ = try? run("/sbin/pfctl", "-a", PFAnchor.name, "-F", "all")
        var state = loadState()
        if let token = state.pfToken {
            _ = try? run("/sbin/pfctl", "-X", token)
            state.pfToken = nil
        }
        try writeHosts(domains: [])
        state.appliedAt = nil
        try saveState(state)
        try? FileManager.default.removeItem(at: blocklistFile)
        lastCompiled = nil
        log("Flushed every Netbite rule.")
        return status()
    }

    func status() -> HelperStatus {
        let blocklist = try? Blocklist.load(from: blocklistFile)
        if lastCompiled == nil, let blocklist {
            lastCompiled = RuleCompiler.compile(blocklist, geo: blocklist.blockedCountries.isEmpty ? nil : try? loadGeo(download: false))
        }
        // stdout only: pfctl prints warnings such as "No ALTQ support in kernel" on stderr, which
        // would otherwise make an empty anchor look loaded.
        let info = dryRun ? "" : ((try? run("/sbin/pfctl", "-s", "info", stdoutOnly: true)) ?? "")
        let anchorRules = dryRun ? "" : ((try? run("/sbin/pfctl", "-a", PFAnchor.name, "-s", "rules", stdoutOnly: true)) ?? "")
        return HelperStatus(
            version: NetbiteVersion.current,
            pfEnabled: info.contains("Status: Enabled"),
            anchorLoaded: !anchorRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            appliedAt: loadState().appliedAt,
            blocklist: blocklist,
            blockTableCount: lastCompiled?.blockTable.count ?? 0,
            geoTableCount: lastCompiled?.geoTable.count ?? 0,
            hostsDomainCount: lastCompiled?.hostsDomains.count ?? 0,
            warnings: lastCompiled?.warnings ?? []
        )
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

    private func writeHosts(domains: [String]) throws {
        let current = (try? String(contentsOf: hostsFile, encoding: .utf8)) ?? ""
        let updated = HostsFile.render(existing: current, domains: domains)
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
            // The helper serves one request at a time, so waiting here is fine.
            let done = DispatchSemaphore(value: 0)
            let outcome = Outcome()
            let destination = geoFile
            Task.detached {
                do { try await GeoIPUpdater.update(to: destination) } catch { outcome.error = error }
                done.signal()
            }
            done.wait()
            if let error = outcome.error { throw error }
        }
        return try GeoIPDatabase(contentsOf: geoFile)
    }

    // MARK: - Plumbing

    private func loadState() -> State {
        (try? JSONDecoder.netbite.decode(State.self, from: Data(contentsOf: stateFile))) ?? State()
    }

    private func saveState(_ state: State) throws {
        try writeFile(JSONEncoder.netbite.encode(state), to: stateFile, mode: 0o600)
    }

    private func writeFile(_ data: Data, to url: URL, mode: mode_t) throws {
        if dryRun {
            try data.write(to: url, options: .atomic)
        } else {
            try SecureFiles.write(data, to: url.path, mode: mode)
        }
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

private final class Outcome: @unchecked Sendable {
    var error: Error?
}

/// Every log line goes through `LogText.sanitized`: messages can carry text sent by a client.
func log(_ message: String) {
    let line = "\(Date().formatted(.iso8601)) \(LogText.sanitized(message))\n"
    FileHandle.standardError.write(Data(line.utf8))
}
