import Darwin
import Foundation

/// A user account of this Mac, as the user database gives it.
public struct LocalAccount: Hashable, Sendable {
    public var name: String
    public var userID: uid_t
    public var home: String

    public init(name: String, userID: uid_t, home: String) {
        self.name = name
        self.userID = userID
        self.home = home
    }

    private static let lock = NSLock()

    /// The name and primary group of `userID`, copied out while the lookup's buffer is alive.
    public static func lookup(userID: uid_t) -> (name: String, groupID: gid_t)? {
        var record = passwd()
        var found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4_096)
        return buffer.withUnsafeMutableBufferPointer { storage -> (String, gid_t)? in
            guard getpwuid_r(userID, &record, storage.baseAddress, storage.count, &found) == 0, found != nil,
                  let name = record.pw_name else { return nil }
            return (String(cString: name), record.pw_gid)
        }
    }

    /// The user ID of the account called `name`.
    public static func userID(named name: String) -> uid_t? {
        var record = passwd()
        var found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4_096)
        return buffer.withUnsafeMutableBufferPointer { storage -> uid_t? in
            guard getpwnam_r(name, &record, storage.baseAddress, storage.count, &found) == 0, found != nil else { return nil }
            return record.pw_uid
        }
    }

    /// Every account with a home folder of its own, root first, at most `limit`. Service accounts
    /// that live in /var/empty are left out; accounts with a low user ID are not, since a hidden
    /// account is given one on purpose. Accounts sharing a home folder count once.
    public static func all(limit: Int = 256) -> [LocalAccount] {
        // getpwent keeps its position in shared state.
        lock.lock()
        defer { lock.unlock() }
        var accounts: [LocalAccount] = []
        setpwent()
        defer { endpwent() }
        var read = 0
        while let entry = getpwent(), read < 4_096 {
            read += 1
            guard let name = entry.pointee.pw_name, let directory = entry.pointee.pw_dir else { continue }
            let home = String(cString: directory)
            guard home.hasPrefix("/"), home != "/", home != "/dev/null", !home.hasPrefix("/var/empty") else { continue }
            accounts.append(LocalAccount(name: String(cString: name), userID: entry.pointee.pw_uid, home: home))
        }
        accounts.sort { ($0.userID, $0.name) < ($1.userID, $1.name) }
        var homes = Set<String>()
        return Array(accounts.filter { homes.insert($0.home).inserted }.prefix(limit))
    }
}

/// What only root can read about persistence: the helper's answer to `rootPersistence`.
///
/// It is made for one reader (`viewer`): text that can hold a secret (a cron command, the comment
/// of a key, a login hook) is given for the reader's own files, never for another user's, and for
/// root's only to a reader who typed an administrator's password (`includesRootText`). Shell
/// startup files and sudoers are described by facts and red flags only, whoever they belong to.
public struct PrivilegedPersistence: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public var name: String
        public var items: [PersistenceItem]
        public var notes: [String]
        /// False when the place could not be read: its absence of items then means nothing.
        public var complete: Bool

        public init(name: String, items: [PersistenceItem] = [], notes: [String] = [], complete: Bool = true) {
            self.name = name
            self.items = items
            self.notes = notes
            self.complete = complete
        }
    }

    public static let cronTables = "Crontabs of every user"
    public static let sudoers = "sudoers"
    public static let authorizedKeys = "SSH authorized keys of every user"
    public static let shellStartup = "Shell startup files of every user"
    public static let rootLoginHooks = "Login hooks (root)"

    /// The categories this report adds items to. The app keeps what it knows of them apart from
    /// what it saw without the helper, so the first report does not announce everything as new.
    public static let categories: Set<PersistenceItem.Category> = [.cronJob, .sudoRule, .sshKey, .shellStartup, .loginHook]

    public var sources: [Source]
    /// The text of root's entries is in the report; when false they read "command hidden".
    public var includesRootText: Bool

    public init(sources: [Source], includesRootText: Bool = false) {
        self.sources = sources
        self.includesRootText = includesRootText
    }

    public func source(_ name: String) -> Source? { sources.first { $0.name == name } }
}

/// Reads the persistence locations that need root. Run by the helper for an administrator, and by
/// `sudo hector persistence` directly.
///
/// It takes nothing from the client: every path is a constant or comes from the user database,
/// and every file is opened through `GuardedDirectory`. It only reads, starts no program, and what
/// it returns is bounded.
public struct PrivilegedPersistenceScanner: Sendable {
    /// `/` on a real system; a folder of fixtures in tests and dry runs.
    public var system: String
    public var accounts: [LocalAccount]

    public init(system: String = "/", accounts: [LocalAccount] = LocalAccount.all()) {
        self.system = system
        self.accounts = accounts
    }

    static let maximumCrontabSize = 1 << 20
    static let maximumSudoersSize = 1 << 20
    static let maximumJobsPerCrontab = 500
    /// Items one source may return. Reaching it takes hundreds of accounts or thousands of
    /// entries; it keeps the answer, and the helper's memory, bounded whatever is on disk.
    static let maximumItemsPerSource = 5_000

    /// `includesRootText`: the reader proved an administrator's password (or is root).
    public func scan(viewer: uid_t, includesRootText: Bool = false) -> PrivilegedPersistence {
        let rootText = includesRootText || viewer == 0
        let root: GuardedDirectory
        do {
            root = try GuardedDirectory(trusted: system)
        } catch {
            return PrivilegedPersistence(sources: [.init(name: PrivilegedPersistence.cronTables, notes: [String(describing: error)], complete: false)],
                                         includesRootText: rootText)
        }
        let users = UserFiles.scan(accounts: accounts, root: root, viewer: viewer, rootText: rootText)
        return PrivilegedPersistence(sources: [
            cronTables(root, viewer: viewer, rootText: rootText),
            sudoers(root),
            .init(name: PrivilegedPersistence.authorizedKeys, items: users.keys),
            .init(name: PrivilegedPersistence.shellStartup, items: users.startup, notes: users.notes),
            rootLoginHooks(root, rootText: rootText),
        ], includesRootText: rootText)
    }

    // MARK: - cron

    func cronTables(_ root: GuardedDirectory, viewer: uid_t, rootText: Bool) -> PrivilegedPersistence.Source {
        var source = PrivilegedPersistence.Source(name: PrivilegedPersistence.cronTables)
        let tabs: GuardedDirectory
        let listing: (names: [String], complete: Bool)
        do {
            // The real path: /usr/lib/cron is a symbolic link to it.
            tabs = try root.descend("private/var/at/tabs")
            listing = try tabs.names(limit: 512)
        } catch {
            source.complete = error.isMissing
            if !error.isMissing { source.notes.append("\(error)") }
            return source
        }
        if !listing.complete { source.notes.append("more than 512 crontabs: the rest were not read") }
        for name in listing.names where !name.hasPrefix(".") {
            guard source.items.count < Self.maximumItemsPerSource else {
                source.notes.append("more than \(Self.maximumItemsPerSource) cron jobs: the rest are not listed")
                break
            }
            let owner = PersistenceParsers.displayable(name, maximumLength: 64)
            let path = "/usr/lib/cron/tabs/" + owner
            guard let contents = try? tabs.read(name, maximumSize: Self.maximumCrontabSize) else {
                source.notes.append("\(path) could not be read")
                continue
            }
            if contents.truncated { source.notes.append("\(path) is larger than 1 MB: only its beginning was read") }
            // The account list counts a shared home folder once and stops at a limit: on a real
            // system ask the user database, so a reader's own table is never taken for a stranger's.
            let ownerID = accounts.first { $0.name == name }?.userID ?? (system == "/" ? LocalAccount.userID(named: name) : nil)
            let scope: PersistenceItem.Scope = name == "root" ? .system : .user
            var jobs = PersistenceParsers.crontab(String(decoding: contents.data, as: UTF8.self), owner: owner, path: path, scope: scope)
            if jobs.count > Self.maximumJobsPerCrontab {
                jobs.removeLast(jobs.count - Self.maximumJobsPerCrontab)
                source.notes.append("\(path) has more than \(Self.maximumJobsPerCrontab) jobs: the rest are not listed")
            }
            let visible = viewer == 0 || (name == "root" && rootText) || (ownerID != nil && ownerID == viewer)
            for (index, job) in jobs.enumerated() {
                var item = job
                item.modifiedAt = contents.facts.modified
                if visible {
                    item.label = PersistenceParsers.displayable(item.label)
                    item.arguments = item.arguments.prefix(64).map { PersistenceParsers.displayable($0) }
                    item.executablePath = item.executablePath.map { PersistenceParsers.displayable($0) }
                    item.details = item.details.mapValues { PersistenceParsers.displayable($0, maximumLength: 200) }
                    // The parser's identifier holds the raw line: rebuild it from what is shown.
                    item.id = PersistenceItem.makeID(category: .cronJob, configurationPath: path,
                                                     label: "\(item.details["schedule"] ?? "") \(item.label)")
                } else {
                    // A command line can hold a password or a token: another user's is never
                    // given, root's only to a reader who typed the password.
                    item = PersistenceItem(category: .cronJob, scope: scope, label: "Cron job of \(owner) (command hidden)",
                                           configurationPath: path, modifiedAt: contents.facts.modified,
                                           details: ["schedule": PersistenceParsers.displayable(job.details["schedule"] ?? "", maximumLength: 200),
                                                     "user": owner],
                                           id: PersistenceItem.makeID(category: .cronJob, configurationPath: path, label: "hidden \(index + 1)"))
                }
                if name == "root" { item.notes.append("runs as root") }
                source.items.append(item)
            }
        }
        return source
    }

    // MARK: - sudoers

    func sudoers(_ root: GuardedDirectory) -> PrivilegedPersistence.Source {
        var source = PrivilegedPersistence.Source(name: PrivilegedPersistence.sudoers)
        let etc: GuardedDirectory
        do {
            etc = try root.descend("private/etc")
        } catch {
            source.complete = false
            source.notes.append("\(error)")
            return source
        }

        func add(_ directory: GuardedDirectory, _ name: String, label: String, path: String, main: Bool) {
            let contents: GuardedDirectory.Contents
            do {
                contents = try directory.read(name, maximumSize: Self.maximumSudoersSize)
            } catch {
                if !error.isMissing {
                    // A link or a pipe where sudo expects a file is worth showing in itself.
                    source.items.append(PersistenceItem(category: .sudoRule, scope: .system, label: label, configurationPath: path,
                                                        notes: ["could not be read: \(error)"]))
                }
                return
            }
            let facts = PersistenceParsers.sudoers(contents.data)
            var notes = facts.notes
            if contents.facts.owner != 0 { notes.append("configuration is not owned by root") }
            if contents.facts.isWritableByOthers { notes.append("configuration is writable by others") }
            if contents.truncated { notes.append("larger than 1 MB: only the beginning was checked") }
            if !main { notes.insert("not part of macOS", at: 0) }
            source.items.append(PersistenceItem(
                category: .sudoRule, scope: main && facts.isStock && notes.isEmpty ? .apple : .system, label: label,
                configurationPath: path, modifiedAt: contents.facts.modified,
                details: ["rules": String(facts.ruleCount)], notes: notes))
        }

        add(etc, "sudoers", label: "sudoers", path: "/etc/sudoers", main: true)
        if let folder = try? etc.directory("sudoers.d"), let listing = try? folder.names(limit: 256) {
            if !listing.complete { source.notes.append("more than 256 files in /etc/sudoers.d: the rest were not read") }
            // sudo itself skips names with a dot or a trailing tilde.
            for name in listing.names where !name.contains(".") && !name.hasSuffix("~") {
                let shown = PersistenceParsers.displayable(name, maximumLength: 100)
                add(folder, name, label: "sudoers.d/\(shown)", path: "/etc/sudoers.d/\(shown)", main: false)
            }
        }
        return source
    }

    // MARK: - Login hooks

    func rootLoginHooks(_ root: GuardedDirectory, rootText: Bool) -> PrivilegedPersistence.Source {
        var source = PrivilegedPersistence.Source(name: PrivilegedPersistence.rootLoginHooks)
        do {
            let preferences = try root.descend("private/var/root/Library/Preferences")
            source.items = LoginHooks.items(in: preferences, displayPath: "/var/root/Library/Preferences/" + LoginHooks.fileName,
                                            showsCommand: rootText)
        } catch {
            source.complete = error.isMissing
            if !error.isMissing { source.notes.append("\(error)") }
        }
        return source
    }
}

/// `LoginHook` and `LogoutHook` of `com.apple.loginwindow`: a program loginwindow runs as root at
/// every login or logout. Deprecated for years and still honored; set in root's preferences or in
/// /Library/Preferences.
enum LoginHooks {
    static let fileName = "com.apple.loginwindow.plist"

    /// `showsCommand` false: that a hook is set, without what it runs.
    static func items(in preferences: GuardedDirectory, displayPath: String, showsCommand: Bool = true) -> [PersistenceItem] {
        guard let contents = try? preferences.read(fileName, maximumSize: 1 << 20), !contents.truncated,
              let plist = (try? PropertyListSerialization.propertyList(from: contents.data, format: nil)) as? [String: Any] else { return [] }
        var items: [PersistenceItem] = []
        for key in ["LoginHook", "LogoutHook"] {
            guard let value = plist[key] as? String, !value.isEmpty else { continue }
            let command = showsCommand ? PersistenceParsers.displayable(value) : "(command hidden)"
            let arguments = showsCommand ? command.split(separator: " ").map(String.init) : []
            var notes = ["runs as root at every \(key == "LoginHook" ? "login" : "logout")"]
            if contents.facts.owner != 0 { notes.append("configuration is not owned by root") }
            if contents.facts.permissions & 0o002 != 0 { notes.append("configuration is world-writable") }
            items.append(PersistenceItem(category: .loginHook, scope: .system, label: showsCommand ? "\(key): \(command)" : "\(key) \(command)",
                                         configurationPath: displayPath,
                                         executablePath: arguments.first.flatMap { $0.hasPrefix("/") ? $0 : nil }, arguments: arguments,
                                         modifiedAt: contents.facts.modified, details: ["hook": key], notes: notes,
                                         id: PersistenceItem.makeID(category: .loginHook, configurationPath: displayPath, label: key)))
        }
        return items
    }
}

/// The files in a home folder that run something, or let someone in, when their owner logs in:
/// authorized SSH keys and shell startup files.
enum UserFiles {
    static let maximumKeysFileSize = 1 << 20
    static let maximumStartupFileSize = 512 << 10

    static let keyFiles = ["authorized_keys", "authorized_keys2"]
    /// Read by zsh, bash, sh, fish and sshd; as path components below the home folder.
    static let startupFiles: [[String]] = [
        [".zshenv"], [".zprofile"], [".zshrc"], [".zlogin"], [".zlogout"],
        [".bash_profile"], [".bash_login"], [".bashrc"], [".bash_logout"], [".profile"],
        [".config", "fish", "config.fish"], [".ssh", "rc"],
    ]

    struct Result {
        var keys: [PersistenceItem] = []
        var startup: [PersistenceItem] = []
        var notes: [String] = []
    }

    /// Home folders are reached from `root` without following a symbolic link: /var and /etc are
    /// links on macOS, so those are spelled out first.
    static func components(ofHome home: String) -> [String] {
        var path = home
        for linked in ["/var/", "/etc/", "/tmp/"] where path.hasPrefix(linked) { path = "/private" + path }
        return path.split(separator: "/").map(String.init)
    }

    static func scan(accounts: [LocalAccount], root: GuardedDirectory, viewer: uid_t, rootText: Bool) -> Result {
        var result = Result()
        for account in accounts {
            guard result.keys.count < PrivilegedPersistenceScanner.maximumItemsPerSource else {
                result.notes.append("more than \(PrivilegedPersistenceScanner.maximumItemsPerSource) authorized keys: the remaining accounts were not read")
                break
            }
            let home: GuardedDirectory
            do {
                home = try root.descend(components(ofHome: account.home))
            } catch {
                if !error.isMissing, !isProtectedSystemHome(account, error) {
                    result.notes.append("home folder of \(PersistenceParsers.displayable(account.name, maximumLength: 64)) was not read: \(error)")
                }
                continue
            }
            let showsText = viewer == 0 || account.userID == viewer || (account.userID == 0 && rootText)
            let one = scan(account: account, home: home, showsText: showsText)
            result.keys += one.keys
            result.startup += one.startup
        }
        return result
    }

    /// macOS keeps even root out of the folders of some of its own service accounts
    /// (`_usbmuxd` in /var/db/lockdown, `_biome`…). Nobody can plant a file there either, so a
    /// refusal for an account whose name starts with an underscore is not worth a warning; for
    /// any other account it is.
    static func isProtectedSystemHome(_ account: LocalAccount, _ error: GuardedDirectory.Failure) -> Bool {
        account.name.hasPrefix("_") && (error.code == EPERM || error.code == EACCES)
    }

    static func scan(account: LocalAccount, home: GuardedDirectory, showsText: Bool) -> Result {
        var result = Result()
        let user = PersistenceParsers.displayable(account.name, maximumLength: 64)
        let homePath = PersistenceParsers.displayable(account.home, maximumLength: 400)
        let scope: PersistenceItem.Scope = account.userID == 0 ? .system : .user

        /// Notes about who may change a file. A file its user does not own is not read at all:
        /// it may be a hard link to something that is not theirs.
        func ownership(_ facts: GuardedDirectory.Facts) -> (notes: [String], readable: Bool) {
            var notes: [String] = []
            if facts.owner != account.userID { notes.append("not owned by \(user) (owner: user \(facts.owner)); not read") }
            if facts.isWritableByOthers { notes.append("writable by others") }
            return (notes, facts.owner == account.userID)
        }

        if let ssh = try? home.directory(".ssh") {
            for name in keyFiles {
                let path = "\(homePath)/.ssh/\(name)"
                let contents: GuardedDirectory.Contents
                do {
                    contents = try ssh.read(name, maximumSize: maximumKeysFileSize)
                } catch {
                    if !error.isMissing {
                        result.keys.append(PersistenceItem(category: .sshKey, scope: scope, label: "~\(user)/.ssh/\(name)", configurationPath: path,
                                                           details: ["user": user], notes: ["could not be read: \(error)"]))
                    }
                    continue
                }
                let (fileNotes, readable) = ownership(contents.facts)
                guard readable else {
                    result.keys.append(PersistenceItem(category: .sshKey, scope: scope, label: "~\(user)/.ssh/\(name)", configurationPath: path,
                                                       modifiedAt: contents.facts.modified, details: ["user": user], notes: fileNotes))
                    continue
                }
                let parsed = PersistenceParsers.authorizedKeys(contents.data)
                for key in parsed.keys {
                    var notes = fileNotes
                    var details = ["user": user, "type": key.type, "fingerprint": key.fingerprint]
                    if !key.options.isEmpty { details["options"] = key.options.joined(separator: ", ") }
                    if account.userID == 0 { notes.append("lets the holder of this key log in as root") }
                    if key.forcedCommand != nil {
                        notes.append("runs a command at login (command=)")
                        if showsText { details["command"] = key.forcedCommand }
                    }
                    if key.options.contains("cert-authority") { notes.append("trusts every key signed by this authority") }
                    if key.options.contains("environment") { notes.append("sets environment variables at login") }
                    let label = showsText && !key.comment.isEmpty ? key.comment : "\(key.type) key of \(user)"
                    result.keys.append(PersistenceItem(category: .sshKey, scope: scope, label: label, configurationPath: path,
                                                       modifiedAt: contents.facts.modified, details: details, notes: notes,
                                                       id: PersistenceItem.makeID(category: .sshKey, configurationPath: path, label: key.fingerprint)))
                }
            }
        }

        for components in startupFiles {
            guard let folder = try? home.descend(Array(components.dropLast())), let name = components.last else { continue }
            let relative = components.joined(separator: "/")
            let path = "\(homePath)/\(relative)"
            var item = PersistenceItem(category: .shellStartup, scope: scope, label: "~\(user)/\(relative)", configurationPath: path,
                                       details: ["user": user])
            do {
                let contents = try folder.read(name, maximumSize: maximumStartupFileSize)
                let (fileNotes, readable) = ownership(contents.facts)
                item.modifiedAt = contents.facts.modified
                item.details["size"] = String(contents.facts.size)
                item.notes = (readable ? PersistenceParsers.shellStartupNotes(contents.data) : []) + fileNotes
                if readable, contents.truncated { item.notes.append("larger than 512 KB: only the beginning was checked") }
            } catch {
                if error.isMissing { continue }
                item.notes = ["could not be read: \(error)"]
            }
            result.startup.append(item)
        }
        return result
    }
}
