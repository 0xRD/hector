import Darwin
import Foundation
import HectorCore

// `hector lists`: the hosts lists catalog, what the helper holds, and tools to check a list
// without root.

func lists(_ args: Arguments) async throws {
    let socket = args.options["--socket"] ?? HelperPaths.socket
    switch args.positional.first ?? "show" {
    case "show":
        try showLists(socket: socket, json: args.flags.contains("--json"))
    case "refresh":
        let authorization = geteuid() == 0 ? Data() : try HelperAuthorization.externalForm()
        print("Asking the helper to download the subscribed lists…")
        switch try HelperClient.sendChecked(.refreshHostsLists(authorization: authorization), socketPath: socket, timeout: 300) {
        case .status(let status):
            printListStates(status)
            status.warnings.forEach { print("warning: \($0)") }
        case .failure(let message):
            throw CLIError(message)
        case .snapshot, .processes, .toolOutput, .hello:
            throw CLIError("Unexpected reply.")
        }
    case "parse":
        guard args.positional.count == 2 else { throw CLIError("Give one hosts file.") }
        let data = try readBounded(URL(fileURLWithPath: args.positional[1]))
        let result = HostsListParser.parse(data)
        printParse(result)
        if args.flags.contains("--print") { result.domains.forEach { print($0) } }
    case "fetch":
        guard args.positional.count == 2, let source = HostsListCatalog.source(args.positional[1]) else {
            throw CLIError("Give one list identifier: \(HostsListCatalog.all.map(\.id).joined(separator: ", ")).")
        }
        print("Downloading \(source.url.absoluteString)…")
        guard case .downloaded(let result, let etag, _) = try await HostsListDownloader.fetch(source, etag: nil, lastModified: nil) else {
            throw CLIError("The server answered 304 to an unconditional request.")
        }
        printParse(result)
        if let etag { print("ETag: \(etag)") }
        if let out = args.options["--out"] {
            try (result.domains.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            print("Wrote \(out)")
        }
    default:
        throw CLIError("Unknown lists subcommand: \(args.positional[0])")
    }
}

private func showLists(socket: String, json: Bool) throws {
    // The helper is optional here: without it, the catalog alone is shown.
    var status: HelperStatus?
    if FileManager.default.fileExists(atPath: socket), case .status(let reply)? = try? HelperClient.send(.status, socketPath: socket, timeout: 10) {
        status = reply
    }
    if json {
        struct Entry: Encodable {
            let id: String
            let name: String
            let url: String
            let license: String
            let subscribed: Bool?
            let state: HostsListState?
        }
        let entries: [Entry] = HostsListCatalog.all.map { source in
            Entry(id: source.id, name: source.name, url: source.url.absoluteString, license: source.license,
                  subscribed: status?.blocklist.map { $0.hostsLists.contains(source.id) },
                  state: status?.hostsLists?.first { $0.id == source.id })
        }
        print(String(decoding: try JSONEncoder.hector.encode(entries), as: UTF8.self))
        return
    }
    for source in HostsListCatalog.all {
        print("\(source.id)  \(source.name)")
        print("  \(source.summary)")
        print("  \(source.url.absoluteString)  (\(source.license))")
    }
    print("")
    guard let status else {
        print("The helper is not reachable: subscriptions and downloads are not shown.")
        print("Subscribe by adding identifiers to \"hostsLists\" in a blocklist file, then `hector helper apply FILE`.")
        return
    }
    guard status.hostsLists != nil else {
        print("The installed helper predates hosts lists: update it from Hector.app (Blocklists → Update helper…).")
        return
    }
    printListStates(status)
}

private func printListStates(_ status: HelperStatus) {
    let subscribed = status.blocklist?.hostsLists ?? []
    print("Subscribed: \(subscribed.isEmpty ? "none" : subscribed.sorted().joined(separator: ", "))")
    for state in status.hostsLists ?? [] {
        let name = HostsListCatalog.source(state.id)?.name ?? state.id
        var line = "  \(name): \(Display.count(state.domainCount)) domains"
        if let updated = state.updatedAt { line += ", downloaded \(Display.dateTime(updated))" }
        if let checked = state.checkedAt { line += ", checked \(Display.dateTime(checked))" }
        if !subscribed.contains(state.id) { line += " (not subscribed)" }
        print(line)
        if let error = state.lastError { print("    last attempt failed: \(error)") }
    }
    if let count = status.listDomainCount {
        print("/etc/hosts: \(Display.count(status.hostsDomainCount + count)) domains (\(Display.count(status.hostsDomainCount)) personal + \(Display.count(count)) from lists)")
    }
}

private func printParse(_ result: HostsListParseResult) {
    print("\(Display.count(result.domains.count)) valid domains, \(result.invalidLines) invalid lines, \(result.skippedEntries) entries skipped (reserved names, redirections, protected hosts)")
    if result.exceededLimit {
        print("warning: more than \(Display.count(HostsListCatalog.maximumDomainsPerList)) domains; the helper would refuse this list.")
    }
}

/// Reads a file no larger than the download cap.
func readBounded(_ url: URL) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard size <= HostsListCatalog.maximumDownloadSize else {
        throw CLIError("\(url.path) is larger than \(HostsListCatalog.maximumDownloadSize / (1024 * 1024)) MB.")
    }
    return try Data(contentsOf: url)
}

/// The domains of the lists a blocklist subscribes to, for `rules check` and `rules render`:
/// from `--lists-dir DIR` (files named `ID.txt`, as `hector lists fetch ID --out` writes them), or
/// downloaded now with `--fetch-lists`. Without either, lists are left out with a note.
func listsForRules(_ blocklist: Blocklist, _ args: Arguments) async throws -> [String: [String]] {
    var lists: [String: [String]] = [:]
    guard !blocklist.hostsLists.isEmpty else { return lists }
    let directory = args.options["--lists-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    let fetch = args.flags.contains("--fetch-lists")
    if directory == nil && !fetch {
        print("note: hosts lists are downloaded by the helper; add --fetch-lists or --lists-dir DIR to include them here.")
        return lists
    }
    for id in blocklist.hostsLists.sorted() {
        guard let source = HostsListCatalog.source(id) else { continue }
        if let directory {
            let file = directory.appending(path: "\(id).txt")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            lists[id] = HostsListParser.parse(try readBounded(file)).domains
        } else {
            print("Downloading \(source.name)…")
            if case .downloaded(let result, _, _) = try await HostsListDownloader.fetch(source, etag: nil, lastModified: nil) {
                lists[id] = result.domains
            }
        }
    }
    return lists
}
