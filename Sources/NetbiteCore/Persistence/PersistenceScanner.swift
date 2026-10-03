import Darwin
import Foundation

/// Lists everything configured to run automatically on this Mac, in the spirit of KnockKnock.
///
/// The scanner only reads: it parses configuration files and the output of Apple's own listing
/// tools, run by absolute path with argument arrays. It never executes anything it finds and never
/// builds a shell command from what it read.
public struct PersistenceScanner: Sendable {
    /// Where to look. Injectable so tests can point the scanner at a temporary folder of fixtures.
    public struct Roots: Sendable {
        /// The home folder whose per-user items are listed.
        public var home: URL
        /// Prefix for machine-wide paths such as `/Library/LaunchDaemons`; `/` on a real system.
        public var system: URL
        public var userID: uid_t
        public var userName: String

        public init(home: URL, system: URL = URL(fileURLWithPath: "/"), userID: uid_t = getuid(),
                    userName: String = NSUserName()) {
            self.home = home
            self.system = system
            self.userID = userID
            self.userName = userName
        }

        public static var live: Roots {
            Roots(home: FileManager.default.homeDirectoryForCurrentUser)
        }

        func system(_ path: String) -> URL { system.appending(path: path) }
        func home(_ path: String) -> URL { home.appending(path: path) }

        /// Where an absolute path found in a configuration file lives under these roots.
        func onDisk(_ absolute: String) -> String {
            let root = system.standardizedFileURL.path
            guard root != "/", !absolute.hasPrefix(root + "/") else { return absolute }
            return root + absolute
        }
    }

    public struct Options: Sendable {
        /// Also list Apple's own launchd jobs in `/System/Library` and other Apple-scoped items.
        public var includeApple: Bool
        /// Limit the scan to these categories; `nil` scans everything.
        public var categories: Set<PersistenceItem.Category>?

        /// `sfltool dumpbtm` output obtained elsewhere (from the helper, which runs as root). When
        /// set, the scanner parses it instead of running the tool.
        public var backgroundTaskOutput: ToolOutput?

        public init(includeApple: Bool = false, categories: Set<PersistenceItem.Category>? = nil,
                    backgroundTaskOutput: ToolOutput? = nil) {
            self.includeApple = includeApple
            self.categories = categories
            self.backgroundTaskOutput = backgroundTaskOutput
        }

        func wants(_ category: PersistenceItem.Category) -> Bool { categories?.contains(category) ?? true }
    }

    public var roots: Roots
    public var tools: ToolRunner

    public init(roots: Roots = .live, tools: ToolRunner = .live) {
        self.roots = roots
        self.tools = tools
    }

    /// One place persistence can hide, scanned independently of the others.
    struct SourceResult: Sendable {
        var items: [PersistenceItem] = []
        var notes: [String] = []
    }

    private struct Source: Sendable {
        let name: String
        let run: @Sendable () -> SourceResult
    }

    public func scan(options: Options = Options()) -> PersistenceReport {
        let start = Date()
        let sources = makeSources(options)
        let results = Results(count: sources.count)
        // Sources are independent and mostly wait on files or tools, so run them side by side.
        DispatchQueue.concurrentPerform(iterations: sources.count) { index in
            results.set(index, sources[index].run())
        }

        var items: [PersistenceItem] = []
        var statuses: [PersistenceSourceStatus] = []
        for (source, result) in zip(sources, results.all) {
            let kept = result.items.filter { options.wants($0.category) && (options.includeApple || $0.scope != .apple) }
            items += kept
            statuses.append(PersistenceSourceStatus(name: source.name, itemCount: kept.count, notes: result.notes))
        }
        return PersistenceReport(scannedAt: start, duration: Date().timeIntervalSince(start), ranAsRoot: geteuid() == 0,
                                 items: Self.sortedUnique(items), sources: statuses)
    }

    private func makeSources(_ options: Options) -> [Source] {
        var sources: [Source] = []
        let apps = AppIndex(roots: roots)

        if options.wants(.launchAgent) || options.wants(.launchDaemon) {
            // Overrides from `launchctl enable/disable` win over the plist's own Disabled key.
            let (userOverrides, systemOverrides, overrideNotes) = disabledOverrides()
            sources.append(Source(name: "launchctl overrides") { SourceResult(notes: overrideNotes) })

            var folders: [(String, URL, PersistenceItem.Category, PersistenceItem.Scope, [String: Bool])] = [
                ("~/Library/LaunchAgents", roots.home("Library/LaunchAgents"), .launchAgent, .user, userOverrides),
                ("/Library/LaunchAgents", roots.system("Library/LaunchAgents"), .launchAgent, .system, userOverrides),
                ("/Library/LaunchDaemons", roots.system("Library/LaunchDaemons"), .launchDaemon, .system, systemOverrides),
            ]
            if options.includeApple {
                folders += [
                    ("/System/Library/LaunchAgents", roots.system("System/Library/LaunchAgents"), .launchAgent, .apple, userOverrides),
                    ("/System/Library/LaunchDaemons", roots.system("System/Library/LaunchDaemons"), .launchDaemon, .apple, systemOverrides),
                ]
            }
            for (name, folder, category, scope, overrides) in folders where options.wants(category) {
                sources.append(Source(name: name) {
                    launchdItems(in: folder, category: category, scope: scope, overrides: overrides, apps: apps)
                })
            }
        }
        if options.wants(.loginItem) || options.wants(.backgroundTask) {
            let provided = options.backgroundTaskOutput
            sources.append(Source(name: "Login items and background tasks") { backgroundTasks(provided: provided) })
        }
        if options.wants(.cronJob) { sources.append(Source(name: "cron") { cronJobs() }) }
        if options.wants(.periodicScript) { sources.append(Source(name: "periodic") { periodicScripts() }) }
        if options.wants(.systemExtension) { sources.append(Source(name: "System extensions") { systemExtensions() }) }
        if options.wants(.kernelExtension) { sources.append(Source(name: "Kernel extensions") { kernelExtensions() }) }
        if options.wants(.configurationProfile) {
            sources.append(Source(name: "Configuration profiles") { configurationProfiles() })
        }
        if options.wants(.browserExtension) {
            sources.append(Source(name: "Chromium browsers") { chromiumExtensions() })
            sources.append(Source(name: "Firefox") { firefoxExtensions() })
            sources.append(Source(name: "Safari") { safariExtensions() })
        }
        return sources
    }

    static func sortedUnique(_ items: [PersistenceItem]) -> [PersistenceItem] {
        let sorted = items.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            if $0.scope != $1.scope { return $0.scope < $1.scope }
            let byLabel = $0.label.localizedCaseInsensitiveCompare($1.label)
            if byLabel != .orderedSame { return byLabel == .orderedAscending }
            return $0.id < $1.id
        }
        // Identifiers must be unique for SwiftUI lists; two entries can legitimately collide,
        // e.g. the same cron line twice in one crontab.
        var seen: [String: Int] = [:]
        return sorted.map { item in
            var item = item
            let count = seen[item.id, default: 0]
            seen[item.id] = count + 1
            if count > 0 { item.id += "#\(count + 1)" }
            return item
        }
    }

    // MARK: - launchd

    func disabledOverrides() -> (user: [String: Bool], system: [String: Bool], notes: [String]) {
        var notes: [String] = []
        func read(_ domain: String) -> [String: Bool] {
            guard let result = tools.run("/bin/launchctl", ["print-disabled", domain]), result.succeeded else {
                notes.append("could not read the \(domain) overrides")
                return [:]
            }
            return PersistenceParsers.disabledOverrides(result.output)
        }
        return (read("gui/\(roots.userID)"), read("system"), notes)
    }

    func launchdItems(in folder: URL, category: PersistenceItem.Category, scope: PersistenceItem.Scope,
                      overrides: [String: Bool], apps: AppIndex) -> SourceResult {
        guard FileManager.default.fileExists(atPath: folder.path) else { return SourceResult() }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return SourceResult(notes: ["\(folder.path) is not readable"])
        }
        let items = names.filter { $0.hasSuffix(".plist") }.sorted().map { name in
            launchdItem(at: folder.appending(path: name), category: category, scope: scope, overrides: overrides, apps: apps)
        }
        return SourceResult(items: items)
    }

    func launchdItem(at url: URL, category: PersistenceItem.Category, scope: PersistenceItem.Scope,
                     overrides: [String: Bool], apps: AppIndex) -> PersistenceItem {
        let fileLabel = url.deletingPathExtension().lastPathComponent
        let facts = FileFacts(url)
        var item = PersistenceItem(category: category, scope: scope, label: fileLabel, configurationPath: url.path,
                                   modifiedAt: facts.modified)
        item.notes += facts.ownershipNotes(machineWide: scope != .user)

        let plist: [String: Any]
        do {
            guard facts.size ?? 0 < 4 << 20 else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: url)
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                item.notes.append("malformed property list: not a dictionary")
                return item
            }
            plist = dictionary
        } catch let error as CocoaError where error.code == .propertyListReadCorrupt {
            item.notes.append("malformed property list")
            return item
        } catch {
            item.notes.append("unreadable: \(error.localizedDescription)")
            return item
        }

        if let label = plist["Label"] as? String {
            item.label = label
            if label != fileLabel { item.notes.append("label differs from the file name") }
        } else {
            item.notes.append("no Label key; launchd refuses such a job")
        }
        item.id = PersistenceItem.makeID(category: category, configurationPath: url.path, label: item.label)

        let arguments = (plist["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        item.arguments = arguments
        item.runAtLoad = plist["RunAtLoad"] as? Bool
        switch plist["KeepAlive"] {
        case let flag as Bool:
            item.keepAlive = flag
        case is [String: Any]:
            item.keepAlive = true
            item.details["keepAlive"] = "conditional"
        default:
            break
        }
        let plistDisabled = plist["Disabled"] as? Bool
        item.isDisabled = overrides[item.label] ?? plistDisabled

        let associated: [String] = switch plist["AssociatedBundleIdentifiers"] {
        case let one as String: [one]
        case let many as [Any]: many.compactMap { $0 as? String }
        default: []
        }
        item.owningBundleIdentifier = associated.first

        // The app that owns the job: the bundle the plist sits in (SMAppService), else the first
        // associated identifier that matches an installed app.
        let enclosingApp = SocketCollector.appBundle(containing: url.path).path
        let ownerApp = enclosingApp ?? associated.lazy.compactMap { apps.path(for: $0) }.first
        item.owningBundlePath = ownerApp

        if let program = plist["Program"] as? String {
            item.executablePath = program
        } else if let bundleProgram = plist["BundleProgram"] as? String {
            if let ownerApp {
                item.executablePath = URL(fileURLWithPath: ownerApp).appending(path: bundleProgram).path
            } else {
                item.notes.append("BundleProgram \(bundleProgram) could not be resolved: owning app not found")
            }
        } else if let first = arguments.first {
            item.executablePath = first
        } else {
            item.notes.append("no Program, ProgramArguments or BundleProgram")
        }

        if item.owningBundlePath == nil, let executable = item.executablePath {
            let bundle = SocketCollector.appBundle(containing: executable)
            item.owningBundlePath = bundle.path
            item.owningBundleIdentifier = item.owningBundleIdentifier ?? bundle.identifier
        }

        if let interval = plist["StartInterval"] as? Int { item.details["startInterval"] = "\(interval)s" }
        if plist["StartCalendarInterval"] != nil { item.details["calendar"] = "yes" }
        if let paths = plist["WatchPaths"] as? [String] { item.details["watchPaths"] = paths.joined(separator: ", ") }
        if let user = plist["UserName"] as? String { item.details["userName"] = user }

        item.notes += Self.executableNotes(item.executablePath, arguments: arguments, roots: roots)
        return item
    }

    /// Red flags KnockKnock-style tools look for in what a job launches.
    static func executableNotes(_ executable: String?, arguments: [String], roots: Roots) -> [String] {
        guard let executable else { return [] }
        var notes: [String] = []
        if !executable.hasPrefix("/") {
            notes.append("program path is not absolute")
        } else if !FileManager.default.fileExists(atPath: executable),
                  !FileManager.default.fileExists(atPath: roots.onDisk(executable)) {
            notes.append("program does not exist")
        }
        let risky = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]
        if risky.contains(where: executable.hasPrefix) { notes.append("program lives in a world-writable folder") }
        if executable.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) {
            notes.append("program lives in a hidden folder")
        }
        let interpreters = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "python", "python3", "perl", "ruby", "osascript", "node"]
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        if interpreters.contains(tool), arguments.contains(where: { $0 == "-c" || $0 == "-e" }) {
            notes.append("runs an inline script")
        }
        return notes
    }

    // MARK: - Login items and background tasks

    func backgroundTasks(provided: ToolOutput? = nil) -> SourceResult {
        // sfltool asks for an administrator password when not root; only the helper may run it.
        guard provided != nil || geteuid() == 0 else {
            return SourceResult(notes: ["needs the helper: sfltool dumpbtm requires root"])
        }
        guard let result = provided ?? tools.run("/usr/bin/sfltool", ["dumpbtm"]), result.succeeded else {
            return SourceResult(notes: ["sfltool dumpbtm failed"])
        }
        var notes: [String] = []
        if result.truncated { notes.append("sfltool output was truncated") }
        return SourceResult(items: PersistenceParsers.backgroundTaskItems(result.output), notes: notes)
    }

    // MARK: - cron

    func cronJobs() -> SourceResult {
        var result = SourceResult()
        let tabs = roots.system("usr/lib/cron/tabs")
        if let users = try? FileManager.default.contentsOfDirectory(atPath: tabs.path) {
            // Readable only as root; then it covers every user, the current one included.
            for user in users.sorted() where !user.hasPrefix(".") {
                let file = tabs.appending(path: user)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                result.items += PersistenceParsers.crontab(text, owner: user, path: file.path,
                                                           scope: user == "root" ? .system : .user)
            }
        } else if let output = tools.run("/usr/bin/crontab", ["-l"]) {
            if output.succeeded {
                result.items += PersistenceParsers.crontab(output.output, owner: roots.userName, path: nil, scope: .user)
            } else if !output.errorOutput.contains("no crontab") {
                result.notes.append("crontab -l failed")
            }
        } else {
            result.notes.append("crontab is not available")
        }
        let systemTab = roots.system("etc/crontab")
        if let text = try? String(contentsOf: systemTab, encoding: .utf8) {
            // /etc/crontab has a sixth "user" column; the parser keeps it as part of the command.
            result.items += PersistenceParsers.crontab(text, owner: "system", path: systemTab.path, scope: .system)
        }
        return result
    }

    // MARK: - periodic

    /// Scripts macOS shipped in /etc/periodic up to macOS 15 (macOS 26 no longer has the folder).
    static let stockPeriodicScripts: [String: Set<String>] = [
        "daily": ["110.clean-tmps", "130.clean-msgs", "140.clean-rwho", "199.rotate-fax", "310.accounting",
                  "400.status-disks", "420.status-network", "430.status-rwho", "999.local"],
        "weekly": ["320.whatis", "340.noid", "999.local"],
        "monthly": ["199.rotate-fax", "200.accounting", "999.local"],
    ]

    func periodicScripts() -> SourceResult {
        var items: [PersistenceItem] = []
        for period in ["daily", "weekly", "monthly"] {
            for base in ["etc/periodic", "usr/local/etc/periodic"] {
                let folder = roots.system("\(base)/\(period)")
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
                for name in names.sorted() where !name.hasPrefix(".") {
                    let url = folder.appending(path: name)
                    let facts = FileFacts(url)
                    let stock = base == "etc/periodic" && Self.stockPeriodicScripts[period]?.contains(name) == true
                    var notes = facts.ownershipNotes(machineWide: true)
                    if !stock { notes.append("not part of macOS") }
                    items.append(PersistenceItem(category: .periodicScript, scope: stock && facts.owner == 0 ? .apple : .system,
                                                 label: name, configurationPath: url.path, executablePath: url.path,
                                                 modifiedAt: facts.modified, details: ["period": period], notes: notes))
                }
            }
            // 999.local runs these when they exist; macOS does not ship them.
            let local = roots.system("etc/\(period).local")
            if FileManager.default.fileExists(atPath: local.path) {
                let facts = FileFacts(local)
                items.append(PersistenceItem(category: .periodicScript, scope: .system, label: "\(period).local",
                                             configurationPath: local.path, executablePath: local.path,
                                             modifiedAt: facts.modified, details: ["period": period],
                                             notes: facts.ownershipNotes(machineWide: true)))
            }
        }
        return SourceResult(items: items)
    }

    // MARK: - System and kernel extensions

    func systemExtensions() -> SourceResult {
        guard let result = tools.run("/usr/bin/systemextensionsctl", ["list"]) else {
            return SourceResult(notes: ["systemextensionsctl is not available"])
        }
        guard result.succeeded else { return SourceResult(notes: ["systemextensionsctl list failed"]) }
        return SourceResult(items: PersistenceParsers.systemExtensions(result.output))
    }

    func kernelExtensions() -> SourceResult {
        var result = SourceResult()
        var byBundleID: [String: PersistenceItem] = [:]

        // Installed: third-party kexts live in /Library/Extensions whether loaded or not.
        let folder = roots.system("Library/Extensions")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where name.hasSuffix(".kext") {
            let url = folder.appending(path: name)
            let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
            let bundleID = info["CFBundleIdentifier"] as? String ?? name
            let executable = (info["CFBundleExecutable"] as? String).map { url.appending(path: "Contents/MacOS/\($0)").path }
            byBundleID[bundleID] = PersistenceItem(
                category: .kernelExtension, scope: bundleID.hasPrefix("com.apple.") ? .apple : .system, label: bundleID,
                configurationPath: url.path, executablePath: executable,
                version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String,
                modifiedAt: FileFacts(url).modified, details: ["loaded": "no"])
        }

        // Loaded: kmutil also shows kexts loaded from elsewhere.
        if let output = tools.run("/usr/bin/kmutil", ["showloaded", "--list-only"]), output.succeeded {
            for loaded in PersistenceParsers.loadedKernelExtensions(output.output) {
                if var installed = byBundleID[loaded.label] {
                    installed.details.merge(loaded.details) { _, new in new }
                    byBundleID[loaded.label] = installed
                } else {
                    byBundleID[loaded.label] = loaded
                }
            }
        } else {
            result.notes.append("could not list loaded kernel extensions")
        }
        result.items = Array(byBundleID.values)
        return result
    }

    // MARK: - Configuration profiles

    func configurationProfiles() -> SourceResult {
        guard let result = tools.run("/usr/bin/profiles", ["list", "-output", "stdout-xml"]), result.succeeded else {
            return SourceResult(notes: ["could not list configuration profiles"])
        }
        do {
            return SourceResult(items: try PersistenceParsers.configurationProfiles(Data(result.output.utf8)))
        } catch {
            return SourceResult(notes: ["unexpected profiles output"])
        }
    }

    // MARK: - Browser extensions

    /// Chromium-based browsers share one profile layout under Application Support.
    static let chromiumBrowsers: [(name: String, path: String)] = [
        ("Google Chrome", "Google/Chrome"),
        ("Chromium", "Chromium"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
        ("Arc", "Arc/User Data"),
    ]

    func chromiumExtensions() -> SourceResult {
        var items: [PersistenceItem] = []
        let fileManager = FileManager.default
        for browser in Self.chromiumBrowsers {
            let base = roots.home("Library/Application Support/\(browser.path)")
            guard let profiles = try? fileManager.contentsOfDirectory(atPath: base.path) else { continue }
            for profile in profiles.sorted() {
                let extensions = base.appending(path: "\(profile)/Extensions")
                guard let ids = try? fileManager.contentsOfDirectory(atPath: extensions.path) else { continue }
                for id in ids.sorted() where id != "Temp" && !id.hasPrefix(".") {
                    let versions = (try? fileManager.contentsOfDirectory(atPath: extensions.appending(path: id).path)) ?? []
                    // Chrome keeps the previous version until restart; the highest one is current.
                    guard let latest = versions.filter({ !$0.hasPrefix(".") }).max(by: {
                        $0.compare($1, options: .numeric) == .orderedAscending
                    }) else { continue }
                    let folder = extensions.appending(path: "\(id)/\(latest)")
                    if let item = Self.chromiumExtension(at: folder, id: id, browser: browser.name, profile: profile) {
                        items.append(item)
                    }
                }
            }
        }
        return SourceResult(items: items)
    }

    /// Reads one unpacked extension version folder.
    static func chromiumExtension(at folder: URL, id: String, browser: String, profile: String) -> PersistenceItem? {
        let manifestURL = folder.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var details = ["browser": browser, "profile": profile, "extensionID": id]
        guard let manifest else {
            return PersistenceItem(category: .browserExtension, scope: .user, label: id, configurationPath: manifestURL.path,
                                   details: details, notes: ["malformed manifest.json"])
        }

        let rawName = manifest["name"] as? String ?? id
        let name = localized(rawName, in: folder, defaultLocale: manifest["default_locale"] as? String) ?? rawName
        let permissions = (manifest["permissions"] as? [Any] ?? []) + (manifest["host_permissions"] as? [Any] ?? [])
        details["permissions"] = String(permissions.count)

        var notes: [String] = []
        let strings = permissions.compactMap { $0 as? String }
        if strings.contains(where: { ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"].contains($0) }) {
            notes.append("can read and change data on all websites")
        }
        if strings.contains("nativeMessaging") { notes.append("can talk to native apps") }
        if manifest["update_url"] == nil { notes.append("no update URL: installed outside the web store or unpacked") }

        return PersistenceItem(category: .browserExtension, scope: .user, label: name, configurationPath: manifestURL.path,
                               version: manifest["version"] as? String, modifiedAt: FileFacts(manifestURL).modified,
                               details: details, notes: notes,
                               id: PersistenceItem.makeID(category: .browserExtension,
                                                          configurationPath: "\(browser)/\(profile)", label: id))
    }

    /// Resolves `__MSG_key__` names from `_locales/<locale>/messages.json`; keys are case-insensitive.
    static func localized(_ value: String, in folder: URL, defaultLocale: String?) -> String? {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__"), value.count > 8 else { return nil }
        let key = value.dropFirst(6).dropLast(2).lowercased()
        var locales: [String] = []
        for locale in [defaultLocale, "en", "en_US"].compactMap({ $0 }) where !locales.contains(locale) {
            locales.append(locale)
        }
        for locale in locales {
            let url = folder.appending(path: "_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: url),
                  let messages = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for (candidate, entry) in messages where candidate.lowercased() == key {
                if let message = (entry as? [String: Any])?["message"] as? String { return message }
            }
        }
        return nil
    }

    func firefoxExtensions() -> SourceResult {
        let profiles = roots.home("Library/Application Support/Firefox/Profiles")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: profiles.path) else { return SourceResult() }
        var result = SourceResult()
        for profile in names.sorted() {
            let url = profiles.appending(path: "\(profile)/extensions.json")
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                result.items += try PersistenceParsers.firefoxExtensions(data, path: url.path, profile: profile)
            } catch {
                result.notes.append("malformed \(url.path)")
            }
        }
        return result
    }

    func safariExtensions() -> SourceResult {
        guard let result = tools.run("/usr/bin/pluginkit", ["-mAvvv", "-p", "com.apple.Safari.web-extension"]),
              result.succeeded else {
            return SourceResult(notes: ["could not list Safari extensions"])
        }
        return SourceResult(items: PersistenceParsers.safariExtensions(result.output))
    }
}

// MARK: - Helpers

/// What the file system says about a configuration file.
struct FileFacts {
    var modified: Date?
    var owner: UInt32?
    var permissions: Int?
    var size: Int?

    init(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        modified = attributes[.modificationDate] as? Date
        owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        size = (attributes[.size] as? NSNumber)?.intValue
    }

    /// A machine-wide job runs for every user or as root, so anyone who can edit its file can
    /// make it run code with those rights.
    func ownershipNotes(machineWide: Bool) -> [String] {
        var notes: [String] = []
        if let permissions, permissions & 0o002 != 0 { notes.append("configuration is world-writable") }
        if machineWide, let owner, owner != 0 { notes.append("configuration is not owned by root") }
        return notes
    }
}

/// Bundle identifier → app path for the apps in /Applications and ~/Applications, built on first
/// use. Resolves `AssociatedBundleIdentifiers` without asking Launch Services, so tests can use it.
final class AppIndex: @unchecked Sendable {
    private let roots: PersistenceScanner.Roots
    private let lock = NSLock()
    private var index: [String: String]?

    init(roots: PersistenceScanner.Roots) { self.roots = roots }

    func path(for bundleIdentifier: String) -> String? {
        lock.withLock {
            if index == nil { index = build() }
            return index?[bundleIdentifier]
        }
    }

    private func build() -> [String: String] {
        var result: [String: String] = [:]
        let fileManager = FileManager.default
        func add(_ folder: URL, depth: Int) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = folder.appending(path: name)
                if name.hasSuffix(".app") {
                    let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist"))
                    if let identifier = info?["CFBundleIdentifier"] as? String, result[identifier] == nil {
                        result[identifier] = url.path
                    }
                } else if depth > 0 {
                    // One level of folders such as /Applications/Utilities.
                    add(url, depth: depth - 1)
                }
            }
        }
        add(roots.system("Applications"), depth: 1)
        add(roots.home("Applications"), depth: 1)
        return result
    }
}

/// Fixed-size result slots filled concurrently.
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [PersistenceScanner.SourceResult]

    init(count: Int) { slots = Array(repeating: PersistenceScanner.SourceResult(), count: count) }

    func set(_ index: Int, _ result: PersistenceScanner.SourceResult) { lock.withLock { slots[index] = result } }
    var all: [PersistenceScanner.SourceResult] { lock.withLock { slots } }
}
