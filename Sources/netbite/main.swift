import Darwin
import Foundation
import NetbiteCore

let version = NetbiteVersion.current

let usage = """
netbite \(version): see which processes talk to which destinations, block destinations system-wide.

USAGE
  netbite connections [--json] [--all] [--resolve] [--db PATH]
      List open internet connections grouped by app. Run with sudo to include other users' processes.
      --all       also show listening and unconnected sockets
      --resolve   reverse-resolve remote addresses (slower)

  netbite geo update                     Download the DB-IP country database (monthly, CC BY 4.0)
  netbite geo lookup IP... [--db PATH]   Country of one or more addresses
  netbite geo ranges CC [--db PATH] [--count]
                                         Networks of a country (ISO code such as CN or RU)

  netbite rules example                  Print an example blocklist file
  netbite rules check FILE [--db PATH]   Validate a blocklist and show what it would block
  netbite rules render FILE --out DIR [--db PATH] [--hosts PATH]
      Write the pf ruleset, pf tables and the resulting hosts file into DIR.
      Nothing on the system is changed: this is what the privileged helper will apply.

  netbite helper status                  State of the privileged helper and of pf
  netbite helper apply FILE              Enforce a blocklist (system-wide, through the helper)
  netbite helper flush                   Remove every Netbite rule
      All helper commands accept --socket PATH. Install the helper from Netbite.app, or with
      sudo netbited install.

  netbite sign PATH... [--json]          Code signature of files or app bundles: trust level, team ID,
                                         notarization, hardened runtime, SHA-256. Nothing is executed.
  netbite vt PATH... [--json] [--refresh]
      Look up the SHA-256 of files on VirusTotal (hash only: files are never uploaded).
      Results are cached for 7 days (1 day for unknown files); free tier: 4 lookups/min, 500/day.
  netbite vt key set                     Store your VirusTotal API key in the Keychain (read from stdin)
  netbite vt key delete                  Remove it

  netbite persistence [--json] [--include-apple] [--category NAME[,NAME]]
      List what is configured to run automatically: launch agents and daemons, login items,
      cron, periodic scripts, system and kernel extensions, profiles, browser extensions.
      Nothing found is executed. Login items need root: they are read through the helper when it
      is installed.

  netbite processes [--json] [--flagged] [--tree]
      Running processes with their parent, user, path and connections. Through the helper when it
      is installed (arguments of every user), else your own processes in full and the others in part.
      --flagged   only processes running from a temporary, Downloads or hidden folder, or whose
                  executable was deleted
      --tree      indent children under their parent

  netbite version | help

Default GeoIP database: \(GeoIPUpdater.defaultDatabaseURL.path)
"""

// MARK: - Argument helpers

struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ raw: ArraySlice<String>, valueOptions: Set<String>) throws {
        var iterator = raw.makeIterator()
        while let arg = iterator.next() {
            if valueOptions.contains(arg) {
                guard let value = iterator.next() else { throw CLIError("\(arg) needs a value.") }
                options[arg] = value
            } else if arg.hasPrefix("--") {
                flags.insert(arg)
            } else {
                positional.append(arg)
            }
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func loadGeo(_ args: Arguments, required: Bool) throws -> GeoIPDatabase? {
    let url = args.options["--db"].map { URL(fileURLWithPath: $0) } ?? GeoIPUpdater.defaultDatabaseURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        if required { throw CLIError("No GeoIP database at \(url.path). Run `netbite geo update` first.") }
        return nil
    }
    return try GeoIPDatabase(contentsOf: url)
}

func endpoint(_ address: IPAddress?, _ port: UInt16) -> String {
    guard let address else { return "*:\(port)" }
    return address.isV4 ? "\(address):\(port)" : "[\(address)]:\(port)"
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// MARK: - Reverse DNS

final class ReverseResolver: @unchecked Sendable {
    private var names: [IPAddress: String] = [:]
    private let lock = NSLock()

    func resolve(_ addresses: [IPAddress]) {
        let unique = Array(Set(addresses))
        DispatchQueue.concurrentPerform(iterations: unique.count) { index in
            let address = unique[index]
            if let name = ReverseDNS.lookup(address) {
                lock.withLock { names[address] = name }
            }
        }
    }

    func name(for address: IPAddress?) -> String? {
        guard let address else { return nil }
        return lock.withLock { names[address] }
    }
}

// MARK: - Commands

func connections(_ args: Arguments) throws {
    let snapshot = SocketCollector(includeUnconnected: args.flags.contains("--all")).snapshot()

    if args.flags.contains("--json") {
        print(String(decoding: try JSONEncoder.netbite.encode(snapshot), as: UTF8.self))
        return
    }
    let geo = try loadGeo(args, required: false)

    let resolver = ReverseResolver()
    if args.flags.contains("--resolve") {
        resolver.resolve(snapshot.processes.flatMap { $0.sockets.compactMap(\.remoteAddress) })
    }

    // Group helpers under their app: Chrome's renderer and GPU helpers show as "Google Chrome".
    let groups = Dictionary(grouping: snapshot.processes) {
        $0.process.appBundleIdentifier ?? $0.process.executablePath ?? $0.process.name
    }
    let ordered = groups.values.sorted {
        $0[0].process.displayName.localizedCaseInsensitiveCompare($1[0].process.displayName) == .orderedAscending
    }

    for group in ordered {
        let first = group[0].process
        let pids = group.map { String($0.process.pid) }.joined(separator: ", ")
        let identity = first.appBundleIdentifier ?? first.executablePath ?? ""
        print("\(first.displayName)  \(identity)  (pid \(pids))")
        let rows = group.flatMap { entry in entry.sockets.map { (entry.process, $0) } }
            .sorted { ($0.1.remoteAddress?.description ?? "") < ($1.1.remoteAddress?.description ?? "") }
        for (index, (process, socket)) in rows.enumerated() {
            let branch = index == rows.count - 1 ? "└" : "├"
            let country = socket.remoteAddress.flatMap { geo?.country(for: $0) } ?? (socket.remoteAddress?.isLocalOrPrivate == true ? "lan" : "--")
            var line = "  \(branch) \(pad(socket.transport.rawValue, 4))"
                + pad(endpoint(socket.remoteAddress, socket.remotePort), 44)
                + pad(country, 5)
                + pad(socket.tcpState ?? "", 13)
            if group.count > 1 { line += process.name }
            if let name = resolver.name(for: socket.remoteAddress) { line += "  \(name)" }
            print(line)
        }
        print("")
    }

    var summary = "\(snapshot.processes.count) processes, \(snapshot.socketCount) sockets."
    if snapshot.unreadableProcessCount > 0 && geteuid() != 0 {
        summary += " \(snapshot.unreadableProcessCount) processes belong to other users: run with sudo to include them."
    }
    if geo == nil {
        summary += " No GeoIP database: run `netbite geo update` to see countries."
    }
    print(summary)
}

func geo(_ args: Arguments) async throws {
    guard let sub = args.positional.first else { throw CLIError("Missing geo subcommand.\n\n\(usage)") }
    switch sub {
    case "update":
        print("Downloading the DB-IP country database…")
        let source = try await GeoIPUpdater.update()
        let db = try GeoIPDatabase(contentsOf: GeoIPUpdater.defaultDatabaseURL)
        print("Installed \(source.lastPathComponent): \(db.rangeCount) ranges, \(db.countries.count) countries.")
        print("Saved to \(GeoIPUpdater.defaultDatabaseURL.path)")
        print(GeoIPUpdater.attribution)
    case "lookup":
        let db = try loadGeo(args, required: true)!
        let ips = args.positional.dropFirst()
        guard !ips.isEmpty else { throw CLIError("Give at least one IP address.") }
        for raw in ips {
            guard let ip = IPAddress(raw) else { throw CLIError("Not an IP address: \(raw)") }
            print("\(ip)\t\(db.country(for: ip) ?? (ip.isLocalOrPrivate ? "private" : "unknown"))")
        }
    case "ranges":
        let db = try loadGeo(args, required: true)!
        guard args.positional.count == 2 else { throw CLIError("Give one ISO country code, e.g. `netbite geo ranges CN`.") }
        let networks = db.networks(for: args.positional[1])
        guard !networks.isEmpty else { throw CLIError("No range for \(args.positional[1].uppercased()).") }
        if args.flags.contains("--count") {
            let v4 = networks.filter(\.network.isV4).count
            print("\(networks.count) networks (\(v4) IPv4, \(networks.count - v4) IPv6)")
        } else {
            networks.forEach { print($0) }
        }
    default:
        throw CLIError("Unknown geo subcommand: \(sub)")
    }
}

func rules(_ args: Arguments) throws {
    guard let sub = args.positional.first else { throw CLIError("Missing rules subcommand.\n\n\(usage)") }
    switch sub {
    case "example":
        let example = Blocklist(rules: [
            Rule(target: RuleTarget("doubleclick.net")!, note: "Google ads"),
            Rule(target: RuleTarget("*.hotjar.com")!, note: "Session recording"),
            Rule(target: RuleTarget("203.0.113.0/24")!, note: "Documentation range (TEST-NET-3)"),
            Rule(target: RuleTarget("198.51.100.17")!, isEnabled: false, note: "Disabled rules are kept but not applied"),
        ], blockedCountries: [])
        print(String(decoding: try JSONEncoder.netbite.encode(example), as: UTF8.self))
    case "check", "render":
        guard args.positional.count == 2 else { throw CLIError("Give one blocklist file.") }
        let blocklist = try Blocklist.load(from: URL(fileURLWithPath: args.positional[1]))
        let compiled = RuleCompiler.compile(blocklist, geo: try loadGeo(args, required: false))
        let countries = blocklist.blockedCountries.isEmpty ? "none" : blocklist.blockedCountries.sorted().joined(separator: ", ")
        print("""
        Rules: \(blocklist.rules.count) (\(blocklist.rules.filter(\.isEnabled).count) enabled)
        Blocked countries: \(countries)
        pf <\(PFAnchor.blockTable)>: \(compiled.blockTable.count) networks
        pf <\(PFAnchor.geoTable)>: \(compiled.geoTable.count) networks
        /etc/hosts: \(compiled.hostsDomains.count) domains
        """)
        compiled.warnings.forEach { print("warning: \($0)") }
        guard sub == "render" else { return }

        guard let outPath = args.options["--out"] else { throw CLIError("render needs --out DIR.") }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let hostsPath = args.options["--hosts"] ?? "/etc/hosts"
        let currentHosts = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        let ruleset = out.appending(path: "netbite.pf.conf")
        try PFAnchor.ruleset(tableDirectory: out.path).write(to: ruleset, atomically: true, encoding: .utf8)
        try PFAnchor.tableFile(compiled.blockTable).write(to: out.appending(path: "\(PFAnchor.blockTable).table"), atomically: true, encoding: .utf8)
        try PFAnchor.tableFile(compiled.geoTable).write(to: out.appending(path: "\(PFAnchor.geoTable).table"), atomically: true, encoding: .utf8)
        try HostsFile.render(existing: currentHosts, domains: compiled.hostsDomains).write(to: out.appending(path: "hosts"), atomically: true, encoding: .utf8)
        print("\nWrote \(out.path)/{netbite.pf.conf, \(PFAnchor.blockTable).table, \(PFAnchor.geoTable).table, hosts}")
        print("The helper would then run:")
        PFAnchor.applyCommands(rulesetPath: ruleset.path).forEach { print("  " + $0.joined(separator: " ")) }
        print("  install \(out.path)/hosts as \(hostsPath), then: dscacheutil -flushcache; killall -HUP mDNSResponder")
    default:
        throw CLIError("Unknown rules subcommand: \(sub)")
    }
}

func helper(_ args: Arguments) throws {
    guard let sub = args.positional.first else { throw CLIError("Missing helper subcommand.\n\n\(usage)") }
    let socket = args.options["--socket"] ?? HelperPaths.socket
    // Changes need an administrator's approval (system dialog) unless we already run as root.
    func authorization() throws -> Data {
        geteuid() == 0 ? Data() : try HelperAuthorization.externalForm()
    }
    let request: HelperRequest
    switch sub {
    case "status": request = .status
    case "flush": request = .flush(authorization: try authorization())
    case "apply":
        guard args.positional.count == 2 else { throw CLIError("Give one blocklist file.") }
        let blocklist = try Blocklist.load(from: URL(fileURLWithPath: args.positional[1]))
        request = .apply(blocklist, authorization: try authorization())
    default: throw CLIError("Unknown helper subcommand: \(sub)")
    }
    switch try HelperClient.send(request, socketPath: socket) {
    case .status(let status):
        print("""
        Helper \(status.version) · pf \(status.pfEnabled ? "enabled" : "disabled") · Netbite anchor \(status.anchorLoaded ? "loaded" : "empty")
        Applied: \(status.appliedAt.map { $0.formatted() } ?? "never")
        pf <\(PFAnchor.blockTable)>: \(status.blockTableCount) networks · <\(PFAnchor.geoTable)>: \(status.geoTableCount) networks · /etc/hosts: \(status.hostsDomainCount) domains
        Blocked countries: \(status.blocklist.map { $0.blockedCountries.sorted().joined(separator: ", ") }.flatMap { $0.isEmpty ? nil : $0 } ?? "none")
        """)
        status.warnings.forEach { print("warning: \($0)") }
    case .snapshot, .processes, .toolOutput:
        print("Unexpected reply.")
    case .failure(let message):
        throw CLIError(message)
    }
}

// MARK: - Entry point

let argv = CommandLine.arguments.dropFirst()
do {
    let command = argv.first ?? "help"
    let args = try Arguments(argv.dropFirst(), valueOptions: ["--db", "--out", "--hosts", "--socket"])
    switch command {
    case "connections", "conn": try connections(args)
    case "geo": try await geo(args)
    case "rules": try rules(args)
    case "helper": try helper(args)
    case "sign", "vt": try await security(command, args)
    case "persistence": try persistence(Arguments(argv.dropFirst(), valueOptions: ["--category", "--socket"]))
    case "processes", "ps": try processes(Arguments(argv.dropFirst(), valueOptions: ["--socket"]))
    case "version", "--version": print("netbite \(version)")
    case "help", "--help", "-h": print(usage)
    default: throw CLIError("Unknown command: \(command)\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("netbite: \(error)\n".utf8))
    exit(1)
}
