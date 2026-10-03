import Foundation

/// Pure parsers for the text the persistence sources print. Kept apart from the scanner so they can
/// be tested with samples, and so the privileged helper can run a root-only tool and hand the
/// output back to the app for parsing.
public enum PersistenceParsers {
    // MARK: - launchctl print-disabled

    /// Parses `launchctl print-disabled <domain>` into label → disabled.
    ///
    /// Recent macOS prints `"label" => disabled|enabled`; older releases printed `=> true|false`,
    /// where `true` meant disabled.
    public static func disabledOverrides(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            switch value {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    // MARK: - sfltool dumpbtm

    /// Parses `sfltool dumpbtm` (root only) into login items and background tasks.
    ///
    /// Legacy agents and daemons are skipped: they are plists in the LaunchAgents/LaunchDaemons
    /// folders and the launchd scan already reports them with their full configuration.
    /// "developer" records only group items by vendor and are skipped too.
    public static func backgroundTaskItems(_ text: String) -> [PersistenceItem] {
        var items: [PersistenceItem] = []
        var uid: Int?
        var record: [String: String] = [:]
        var inRecord = false

        func flush() {
            defer { record = [:]; inRecord = false }
            guard inRecord, let item = backgroundTaskItem(record, uid: uid) else { return }
            items.append(item)
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                flush()
                let number = line.dropFirst("Records for UID".count).split(separator: ":").first
                uid = number.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } else if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                // "#3:" alone starts an item; "#1: 16.com.example" lines are embedded identifiers.
                flush()
                inRecord = true
            } else if inRecord, let colon = line.range(of: ": ") {
                let key = String(line[..<colon.lowerBound])
                if record[key] == nil { record[key] = String(line[colon.upperBound...]) }
            }
        }
        flush()
        return items
    }

    private static func backgroundTaskItem(_ record: [String: String], uid: Int?) -> PersistenceItem? {
        let type = record["Type"].map { $0.components(separatedBy: " (").first ?? $0 } ?? ""
        let category: PersistenceItem.Category
        switch type {
        case "app", "login item": category = .loginItem
        case "agent", "daemon": category = .backgroundTask
        default: return nil
        }

        let identifier = record["Identifier"].map(stripTypePrefix)
        let label = nonNull(record["Name"]) ?? identifier ?? "unnamed"
        let url = nonNull(record["URL"]).flatMap { URL(string: $0) }.map(\.path)
        let executable = nonNull(record["Executable Path"]) ?? url
        let disposition = record["Disposition"] ?? ""
        let bundleID = nonNull(record["Bundle Identifier"])
            ?? nonNull(record["Assoc. Bundle IDs"]).flatMap(firstBracketed)
        let team = nonNull(record["Team Identifier"])

        let scope: PersistenceItem.Scope
        if (identifier ?? "").hasPrefix("com.apple.") || (bundleID ?? "").hasPrefix("com.apple.") {
            scope = .apple
        } else if uid == 0 || type == "daemon" {
            scope = .system
        } else {
            scope = .user
        }

        var notes: [String] = []
        if disposition.contains("disallowed") { notes.append("blocked in Login Items settings") }
        if team == nil, scope != .apple { notes.append("no team identifier (unsigned or ad-hoc signed)") }

        var details: [String: String] = ["type": type]
        if let uid { details["uid"] = String(uid) }
        if let developer = nonNull(record["Developer Name"]) { details["developer"] = developer }
        if let identifier { details["identifier"] = identifier }

        return PersistenceItem(category: category, scope: scope, label: label, configurationPath: url,
                               executablePath: executable, teamIdentifier: team,
                               isDisabled: disposition.contains("disabled") ? true : disposition.contains("enabled") ? false : nil,
                               owningBundleIdentifier: bundleID, details: details, notes: notes,
                               id: PersistenceItem.makeID(category: category, configurationPath: "btm:\(uid ?? -1)",
                                                          label: identifier ?? label))
    }

    /// BTM identifiers carry their type code: "2.com.example.App", "16.com.example.daemon".
    private static func stripTypePrefix(_ identifier: String) -> String {
        guard let dot = identifier.firstIndex(of: "."), Int(identifier[..<dot]) != nil else { return identifier }
        return String(identifier[identifier.index(after: dot)...])
    }

    private static func nonNull(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value != "(null)" else { return nil }
        return value
    }

    private static func firstBracketed(_ value: String) -> String? {
        let inner = value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return nonNull(inner.components(separatedBy: ",").first)
    }

    // MARK: - systemextensionsctl list

    /// Parses `systemextensionsctl list`. Rows are tab-separated under a `--- <category>` heading:
    /// `*	*	TEAMID	com.example.ext (1.2/120)	Name	[activated enabled]`.
    public static func systemExtensions(_ text: String) -> [PersistenceItem] {
        var items: [PersistenceItem] = []
        var kind = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("---") {
                // "--- com.apple.system_extension.network_extension (Go to …)" → "network_extension"
                let identifier = line.dropFirst(3).trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
                kind = identifier.components(separatedBy: ".").last ?? identifier
                continue
            }
            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 6, columns[0] != "enabled",
                  let open = columns[3].lastIndex(of: "(") else { continue }
            let bundleID = columns[3][..<open].trimmingCharacters(in: .whitespaces)
            let versions = columns[3][columns[3].index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            let state = columns[5].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            let team = columns[2].trimmingCharacters(in: .whitespaces)
            guard !bundleID.isEmpty else { continue }

            var notes: [String] = []
            if state.contains("waiting for user") { notes.append("waiting for the user to approve it") }
            var details = ["state": state, "name": columns[4]]
            if !kind.isEmpty { details["type"] = kind }
            items.append(PersistenceItem(
                category: .systemExtension, scope: bundleID.hasPrefix("com.apple.") ? .apple : .system,
                label: bundleID, version: versions.components(separatedBy: "/").first,
                teamIdentifier: team.isEmpty || team == "-" ? nil : team,
                isDisabled: columns[0].trimmingCharacters(in: .whitespaces) != "*",
                owningBundleIdentifier: nil, details: details, notes: notes))
        }
        return items
    }

    // MARK: - kmutil showloaded

    /// Parses `kmutil showloaded --list-only`, keeping third-party kexts only.
    ///
    /// Row: `Index Refs Address Size Wired Name (Version) UUID <Linked Against>`.
    public static func loadedKernelExtensions(_ text: String) -> [PersistenceItem] {
        var items: [PersistenceItem] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 7, Int(fields[0]) != nil, Int(fields[1]) != nil,
                  let nameIndex = fields.firstIndex(where: { $0.hasPrefix("(") }).map({ $0 - 1 }),
                  nameIndex >= 5 else { continue }
            let bundleID = String(fields[nameIndex])
            guard !bundleID.hasPrefix("com.apple.") else { continue }
            let version = fields[nameIndex + 1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            var details = ["loaded": "yes"]
            if fields.count > nameIndex + 2 { details["uuid"] = String(fields[nameIndex + 2]) }
            items.append(PersistenceItem(category: .kernelExtension, scope: .system, label: bundleID,
                                         version: version, details: details,
                                         id: PersistenceItem.makeID(category: .kernelExtension, configurationPath: nil, label: bundleID)))
        }
        return items
    }

    // MARK: - crontab

    /// Parses a crontab, skipping blank lines, comments and `NAME=value` environment lines.
    public static func crontab(_ text: String, owner: String, path: String?, scope: PersistenceItem.Scope) -> [PersistenceItem] {
        var items: [PersistenceItem] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !isEnvironmentLine(line) else { continue }

            let fields = line.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            let schedule: String
            let command: String
            if line.hasPrefix("@") {
                guard fields.count >= 2 else { continue }
                schedule = String(fields[0])
                command = line.dropFirst(schedule.count).trimmingCharacters(in: .whitespaces)
            } else {
                guard fields.count == 6 else { continue }
                schedule = fields[0..<5].joined(separator: " ")
                command = String(fields[5]).trimmingCharacters(in: .whitespaces)
            }
            let arguments = command.split(separator: " ").map(String.init)
            var notes: [String] = []
            if let first = arguments.first, !first.hasPrefix("/") { notes.append("command is not an absolute path") }
            if command.contains("curl ") || command.contains("wget ") { notes.append("downloads from the network") }
            items.append(PersistenceItem(category: .cronJob, scope: scope, label: command, configurationPath: path,
                                         executablePath: arguments.first.flatMap { $0.hasPrefix("/") ? $0 : nil },
                                         arguments: arguments,
                                         details: ["schedule": schedule, "user": owner], notes: notes,
                                         id: PersistenceItem.makeID(category: .cronJob, configurationPath: path ?? "crontab:\(owner)",
                                                                    label: "\(schedule) \(command)")))
        }
        return items
    }

    /// `MAILTO=root`, `PATH = /usr/bin`: an identifier, then `=`, before any whitespace-separated field.
    private static func isEnvironmentLine(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        let name = line[..<equals].trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - pluginkit (Safari web extensions)

    /// Parses `pluginkit -mAvvv -p com.apple.Safari.web-extension`.
    ///
    /// An entry starts with `[+-!=] bundle.id(version)`, where `+` means the user enabled it and
    /// `-` that they turned it off, followed by indented `Key = Value` lines.
    public static func safariExtensions(_ text: String) -> [PersistenceItem] {
        var items: [PersistenceItem] = []
        var header: (election: Character?, bundleID: String, version: String)?
        var fields: [String: String] = [:]

        func flush() {
            defer { header = nil; fields = [:] }
            guard let header else { return }
            let name = fields["Display Name"] ?? fields["Short Name"] ?? header.bundleID
            var details = ["browser": "Safari", "bundleID": header.bundleID]
            if let parentName = fields["Parent Name"] { details["app"] = parentName }
            items.append(PersistenceItem(
                category: .browserExtension, scope: header.bundleID.hasPrefix("com.apple.") ? .apple : .user,
                label: name, configurationPath: fields["Path"], executablePath: fields["Path"],
                version: header.version.isEmpty ? nil : header.version,
                isDisabled: header.election == "-" ? true : header.election == "+" ? false : nil,
                owningBundlePath: fields["Parent Bundle"], details: details,
                id: PersistenceItem.makeID(category: .browserExtension, configurationPath: "safari", label: header.bundleID)))
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let equals = line.range(of: " = ") {
                guard header != nil else { continue }
                fields[line[..<equals.lowerBound].trimmingCharacters(in: .whitespaces)] =
                    line[equals.upperBound...].trimmingCharacters(in: .whitespaces)
            } else if line.hasSuffix(")"), let open = line.lastIndex(of: "("), !line.hasPrefix("(") {
                flush()
                var identifier = line[..<open].trimmingCharacters(in: .whitespaces)
                var election: Character?
                if let first = identifier.first, "+-!=?".contains(first) {
                    election = first
                    identifier = identifier.dropFirst().trimmingCharacters(in: .whitespaces)
                }
                let version = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
                header = (election, identifier, version)
            }
        }
        flush()
        return items
    }

    // MARK: - profiles

    /// Parses `profiles list -output stdout-xml`: a dictionary from user name (or
    /// `_computerlevel`) to an array of profile dictionaries.
    public static func configurationProfiles(_ data: Data) throws -> [PersistenceItem] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return []
        }
        var items: [PersistenceItem] = []
        for (owner, value) in root {
            guard let profiles = value as? [[String: Any]] else { continue }
            for profile in profiles {
                let identifier = profile["ProfileIdentifier"] as? String ?? "unknown"
                let name = profile["ProfileDisplayName"] as? String ?? identifier
                let payloads = (profile["ProfileItems"] as? [[String: Any]] ?? []).compactMap { $0["PayloadType"] as? String }
                var details = ["identifier": identifier, "owner": owner]
                if let organization = profile["ProfileOrganization"] as? String { details["organization"] = organization }
                if !payloads.isEmpty { details["payloads"] = Set(payloads).sorted().joined(separator: ", ") }
                var notes: [String] = []
                // These payloads can intercept or redirect traffic, which is what malicious profiles do.
                let sensitive = ["com.apple.security.root", "com.apple.proxy.http.global", "com.apple.vpn.managed",
                                 "com.apple.dnsSettings.managed", "com.apple.webcontent-filter"]
                for payload in Set(payloads).intersection(sensitive).sorted() { notes.append("installs \(payload)") }
                items.append(PersistenceItem(
                    category: .configurationProfile, scope: owner == "_computerlevel" ? .system : .user,
                    label: name, modifiedAt: profile["ProfileInstallDate"] as? Date, details: details, notes: notes,
                    id: PersistenceItem.makeID(category: .configurationProfile, configurationPath: owner, label: identifier)))
            }
        }
        return items
    }

    // MARK: - Firefox

    /// Parses a Firefox profile's `extensions.json`, keeping the add-ons the user installed.
    public static func firefoxExtensions(_ data: Data, path: String, profile: String) throws -> [PersistenceItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addons = root["addons"] as? [[String: Any]] else { return [] }
        return addons.compactMap { addon in
            // Built-in and system add-ons ship with Firefox itself.
            guard addon["type"] as? String == "extension",
                  let id = addon["id"] as? String,
                  !["app-builtin", "app-system-defaults", "app-system-addons"].contains(addon["location"] as? String ?? "")
            else { return nil }
            let locale = addon["defaultLocale"] as? [String: Any]
            let name = locale?["name"] as? String ?? id
            let permissions = addon["userPermissions"] as? [String: Any]
            let count = (permissions?["permissions"] as? [Any] ?? []).count + (permissions?["origins"] as? [Any] ?? []).count
            let active = addon["active"] as? Bool
            return PersistenceItem(
                category: .browserExtension, scope: .user, label: name, configurationPath: path,
                executablePath: addon["path"] as? String, version: addon["version"] as? String,
                isDisabled: active.map { !$0 },
                details: ["browser": "Firefox", "profile": profile, "extensionID": id, "permissions": String(count)],
                id: PersistenceItem.makeID(category: .browserExtension, configurationPath: path, label: id))
        }
    }
}
