import Darwin
import Foundation

/// Persistence locations beyond launchd and cron: `at` jobs, login hooks, shell startup files,
/// authorized SSH keys, sudo rules, PAM and authorization plugins.
///
/// What every user can read is read here, as the user. What only root can read comes from
/// `PrivilegedPersistence` (the helper's answer, or a scan made in this process when it runs as
/// root); without it the scanner covers the current user's own files and says what is missing.
extension PersistenceScanner {
    /// The current user, for the files in their home folder.
    private var ownAccount: LocalAccount {
        LocalAccount(name: roots.userName, userID: roots.userID, home: roots.home.path)
    }

    private func systemDirectory(_ path: String) -> GuardedDirectory? {
        try? GuardedDirectory(trusted: roots.system.path).descend(path)
    }

    // MARK: - cron

    func cronJobs(tables: PrivilegedPersistence.Source?) -> SourceResult {
        var result = SourceResult()
        if let tables, tables.complete {
            // Every user's table, the current one included.
            result.items += tables.items
            result.notes += tables.notes
        } else {
            result.notes += tables?.notes ?? []
            result.notes.append("the crontabs of root and other users need the helper")
            if let output = tools.run("/usr/bin/crontab", ["-l"]) {
                if output.succeeded {
                    result.items += PersistenceParsers.crontab(output.output, owner: roots.userName, path: nil, scope: .user)
                } else if !output.errorOutput.contains("no crontab") {
                    result.notes.append("crontab -l failed")
                }
            } else {
                result.notes.append("crontab is not available")
            }
        }
        let systemTab = roots.system("etc/crontab")
        if let text = try? String(contentsOf: systemTab, encoding: .utf8) {
            // /etc/crontab has a sixth "user" column; the parser keeps it as part of the command.
            result.items += PersistenceParsers.crontab(text, owner: "system", path: systemTab.path, scope: .system)
        }
        return result
    }

    // MARK: - at

    /// Jobs waiting in the `at` spool. The folder can be listed by anyone; the jobs themselves
    /// (a script with the whole environment of whoever queued it) are never opened.
    func atJobs() -> SourceResult {
        guard let spool = systemDirectory("private/var/at/jobs"), let listing = try? spool.names(limit: 512) else { return SourceResult() }
        var result = SourceResult()
        if !listing.complete { result.notes.append("more than 512 files in the at spool: the rest were not read") }
        for name in listing.names {
            guard let job = PersistenceParsers.atJob(named: name), let facts = spool.facts(of: name), facts.kind == .regular else { continue }
            let owner = Self.userName(facts.owner)
            var notes = ["only runs if com.apple.atrun is enabled (it is disabled by default)"]
            if facts.owner == 0 { notes.append("runs as root") }
            result.items.append(PersistenceItem(
                category: .atJob, scope: facts.owner == 0 ? .system : .user, label: "at job \(job.number) of \(owner)",
                configurationPath: "/usr/lib/cron/jobs/\(name)", modifiedAt: facts.modified,
                details: ["user": owner, "queue": job.queue, "runsAt": job.runsAt.formatted(.iso8601)], notes: notes))
        }
        return result
    }

    static func userName(_ userID: uid_t) -> String {
        guard let name = LocalAccount.lookup(userID: userID)?.name else { return "user \(userID)" }
        return PersistenceParsers.displayable(name, maximumLength: 64)
    }

    // MARK: - Login hooks

    func loginHooks(root: PrivilegedPersistence.Source?) -> SourceResult {
        var result = SourceResult()
        if let preferences = systemDirectory("Library/Preferences") {
            result.items += LoginHooks.items(in: preferences, displayPath: "/Library/Preferences/" + LoginHooks.fileName)
        }
        if let root {
            result.items += root.items
            result.notes += root.notes
        } else {
            result.notes.append("root's login hooks need the helper")
        }
        return result
    }

    // MARK: - Shell startup files

    /// Files of /etc every shell reads. macOS ships most of them, and root can edit them all.
    static let systemShellFiles = ["zshenv", "zprofile", "zshrc", "zlogin", "zlogout", "zshrc_Apple_Terminal",
                                   "profile", "bashrc", "bashrc_Apple_Terminal", "csh.cshrc", "csh.login", "csh.logout"]
    static let stockSystemShellFiles: Set<String> = ["zprofile", "zshrc", "zshrc_Apple_Terminal", "profile", "bashrc",
                                                     "bashrc_Apple_Terminal", "csh.cshrc", "csh.login", "csh.logout"]

    func shellStartupFiles(users: PrivilegedPersistence.Source?) -> SourceResult {
        var result = SourceResult()
        if let etc = systemDirectory("private/etc") {
            for name in Self.systemShellFiles {
                guard let contents = try? etc.read(name, maximumSize: UserFiles.maximumStartupFileSize) else { continue }
                var notes = PersistenceParsers.shellStartupNotes(contents.data)
                if contents.facts.owner != 0 { notes.append("configuration is not owned by root") }
                if contents.facts.isWritableByOthers { notes.append("configuration is writable by others") }
                let stock = Self.stockSystemShellFiles.contains(name)
                if !stock { notes.insert("not part of macOS", at: 0) }
                // A stock file with nothing odd in it is Apple's; one that grew a red flag is not.
                result.items.append(PersistenceItem(category: .shellStartup, scope: stock && notes.isEmpty ? .apple : .system,
                                                    label: "/etc/\(name)", configurationPath: "/etc/\(name)",
                                                    modifiedAt: contents.facts.modified,
                                                    details: ["user": "everyone", "size": String(contents.facts.size)], notes: notes))
            }
        }
        if let users {
            result.items += users.items
            // The 0.5.1 helper reports each service account whose folder macOS keeps from root.
            result.notes += users.notes.filter { !($0.hasPrefix("home folder of _") && $0.hasSuffix("(Operation not permitted)")) }
        } else {
            result.items += ownFiles().startup
            result.notes.append("the shell startup files of root and other users need the helper")
        }
        return result
    }

    // MARK: - SSH authorized keys

    func authorizedKeys(users: PrivilegedPersistence.Source?) -> SourceResult {
        if let users { return SourceResult(items: users.items, notes: users.notes) }
        return SourceResult(items: ownFiles().keys, notes: ["the authorized keys of root and other users need the helper"])
    }

    private func ownFiles() -> UserFiles.Result {
        guard let home = try? GuardedDirectory(trusted: roots.home.path) else { return UserFiles.Result() }
        return UserFiles.scan(account: ownAccount, home: home, showsText: true)
    }

    // MARK: - sudoers

    func sudoRules(_ source: PrivilegedPersistence.Source?) -> SourceResult {
        guard let source else { return SourceResult(notes: ["needs the helper: only root can read /etc/sudoers and /etc/sudoers.d"]) }
        return SourceResult(items: source.items, notes: source.notes)
    }

    // MARK: - PAM

    /// One item per service of /etc/pam.d, and one per module installed in /usr/local/lib/pam.
    /// A module decides who is let in: one that is not Apple's, in the `sudo` or `sshd` service,
    /// is a classic backdoor. Apple's own live in /usr/lib/pam, on the sealed system volume.
    func pamServices() -> SourceResult {
        var result = SourceResult()
        let stock = systemDirectory("usr/lib/pam")
        let local = systemDirectory("usr/local/lib/pam")

        func isApple(_ module: String) -> Bool? {
            if module.hasPrefix("/") { return module.hasPrefix("/usr/lib/pam/") && !module.contains("/../") }
            // macOS installs pam_x.so.2 and services name pam_x.so.
            for candidate in [module, module + ".2"] where GuardedDirectory.isSingleComponent(candidate) {
                if stock?.facts(of: candidate) != nil { return true }
                if local?.facts(of: candidate) != nil { return false }
            }
            return nil
        }

        if let services = systemDirectory("private/etc/pam.d"), let listing = try? services.names(limit: 256) {
            for name in listing.names where !name.hasPrefix(".") && !name.hasSuffix(".template") {
                guard let contents = try? services.read(name, maximumSize: 256 << 10) else { continue }
                let shown = PersistenceParsers.displayable(name, maximumLength: 100)
                var notes: [String] = []
                var modules: [String] = []
                for entry in PersistenceParsers.pamService(contents.data) where entry.control != "include" {
                    if !modules.contains(entry.module) { modules.append(entry.module) }
                    let note: String? = switch isApple(entry.module) {
                    case true?: nil
                    case false?: "loads \(entry.module), which is not part of macOS"
                    case nil: "names a module that is not installed: \(entry.module)"
                    }
                    if let note, !notes.contains(note) { notes.append(note) }
                }
                if contents.facts.owner != 0 { notes.append("configuration is not owned by root") }
                if contents.facts.isWritableByOthers { notes.append("configuration is writable by others") }
                result.items.append(PersistenceItem(category: .pamService, scope: notes.isEmpty ? .apple : .system, label: shown,
                                                    configurationPath: "/etc/pam.d/\(shown)", modifiedAt: contents.facts.modified,
                                                    details: ["modules": modules.prefix(40).joined(separator: ", ")], notes: notes))
            }
        }
        if let local, let listing = try? local.names(limit: 256) {
            for name in listing.names where !name.hasPrefix(".") {
                let shown = PersistenceParsers.displayable(name, maximumLength: 100)
                let facts = local.facts(of: name)
                var notes = ["not part of macOS"]
                if let facts, facts.owner != 0 { notes.append("not owned by root") }
                if let facts, facts.isWritableByOthers, facts.kind != .symbolicLink { notes.append("writable by others") }
                result.items.append(PersistenceItem(category: .pamService, scope: .system, label: shown,
                                                    configurationPath: "/usr/local/lib/pam/\(shown)", executablePath: "/usr/local/lib/pam/\(shown)",
                                                    modifiedAt: facts?.modified, details: ["kind": "module"], notes: notes))
            }
        }
        return result
    }

    // MARK: - Authorization plugins

    /// Bundles of /Library/Security/SecurityAgentPlugins: code that runs inside the login window
    /// and the password dialogs. macOS installs none there.
    func authorizationPlugins() -> SourceResult {
        guard let folder = systemDirectory("Library/Security/SecurityAgentPlugins"), let listing = try? folder.names(limit: 256) else {
            return SourceResult()
        }
        var result = SourceResult()
        for name in listing.names where !name.hasPrefix(".") {
            let shown = PersistenceParsers.displayable(name, maximumLength: 200)
            let path = "/Library/Security/SecurityAgentPlugins/\(shown)"
            let facts = folder.facts(of: name)
            var info: [String: Any] = [:]
            if let contents = try? folder.descend([name, "Contents"]).read("Info.plist", maximumSize: 1 << 20),
               let plist = (try? PropertyListSerialization.propertyList(from: contents.data, format: nil)) as? [String: Any] {
                info = plist
            }
            let executable = (info["CFBundleExecutable"] as? String).map { PersistenceParsers.displayable($0, maximumLength: 200) }
            var notes: [String] = []
            if let facts, facts.owner != 0 { notes.append("not owned by root") }
            if let facts, facts.isWritableByOthers, facts.kind != .symbolicLink { notes.append("writable by others") }
            if facts?.kind == .symbolicLink { notes.append("is a symbolic link") }
            result.items.append(PersistenceItem(
                category: .authorizationPlugin, scope: .system,
                label: (info["CFBundleIdentifier"] as? String).map { PersistenceParsers.displayable($0, maximumLength: 200) } ?? shown,
                configurationPath: path, executablePath: executable.map { "\(path)/Contents/MacOS/\($0)" },
                version: (info["CFBundleShortVersionString"] as? String).map { PersistenceParsers.displayable($0, maximumLength: 40) },
                modifiedAt: facts?.modified, details: ["role": "runs inside the login window and the password dialogs"], notes: notes))
        }
        return result
    }
}
