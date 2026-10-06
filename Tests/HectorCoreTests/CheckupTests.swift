import Foundation
import Testing
@testable import HectorCore

// Sample outputs below reflect macOS 15 (Sequoia) as best known, run with LC_ALL=C as the
// checkup does. They must be compared with the real tools on a Mac (see docs/NEXT_STEPS.md).

private enum Samples {
    static let sipEnabled = "System Integrity Protection status: enabled.\n"
    static let sipDisabled = "System Integrity Protection status: disabled.\n"
    static let sipCustom = """
    System Integrity Protection status: unknown (Custom Configuration).

    Configuration:
    \tApple Internal: disabled
    \tKext Signing: disabled
    \tFilesystem Protections: enabled
    \tDebugging Restrictions: disabled
    \tDTrace Restrictions: enabled
    \tNVRAM Protections: enabled
    \tBaseSystem Verification: enabled
    \tBoot-arg Restrictions: enabled
    \tKernel Integrity Protections: enabled
    \tAuthenticated Root Requirement: enabled

    This is an unsupported configuration, likely to break in the future and leave your machine in an unknown state.

    """

    static let gatekeeperOn = "assessments enabled\n"
    static let gatekeeperOff = "assessments disabled\n"

    static let fileVaultOn = "FileVault is On.\n"
    static let fileVaultOff = "FileVault is Off.\n"
    static let fileVaultEncrypting = "FileVault is On.\nEncryption in progress: Percent completed = 37.4\n"
    static let fileVaultDecrypting = "FileVault is On.\nDecryption in progress: Percent completed = 12.0\n"
    static let fileVaultDeferred = "FileVault is Off.\nDeferred enablement appears to be active for user 'alex'.\n"

    static let firewallOn = "Firewall is enabled. (State = 1)\n"
    static let firewallOff = "Firewall is disabled. (State = 0)\n"
    static let firewallBlockAll = "Firewall is enabled. (State = 2)\n"
    static let stealthOn = "Firewall stealth mode is on\n"
    static let stealthOff = "Firewall stealth mode is off\n"
    static let stealthOldOn = "Stealth mode enabled\n"

    static let notEnrolled = "Enrolled via DEP: No\nMDM enrollment: No\n"
    static let enrolled = """
    Enrolled via DEP: Yes
    MDM enrollment: Yes (User Approved)
    MDM server: https://mdm.example.com/mdm/checkin

    """

    static let overrides = """
    disabled services = {
    \t"com.apple.ftpd" => disabled
    \t"com.apple.mdmclient.daemon.runatboot" => disabled
    \t"com.openssh.sshd" => enabled
    \t"com.apple.screensharing" => disabled
    \t"com.apple.smbd" => enabled
    \t"com.apple.AEServer" => disabled
    }
    login item associations = {
    }

    """
}

/// Answers like the real tools from canned text and remembers what was asked.
private final class CannedTools: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    let answers: [String: ToolOutput]

    init(_ answers: [String: ToolOutput]) { self.answers = answers }

    var runner: ToolRunner {
        ToolRunner { executable, arguments in
            let command = ([executable] + arguments).joined(separator: " ")
            self.lock.withLock { self.calls.append(command) }
            return self.answers[command]
        }
    }

    var invoked: [String] { lock.withLock { calls } }
}

@Suite struct CheckupParserTests {
    @Test func parsesSIP() {
        #expect(CheckupParsers.sip(Samples.sipEnabled) == .enabled)
        #expect(CheckupParsers.sip(Samples.sipDisabled) == .disabled)
        #expect(CheckupParsers.sip(Samples.sipCustom) == .custom(disabledProtections: ["Kext Signing", "Debugging Restrictions"]))
        #expect(CheckupParsers.sip("csrutil: command not found") == nil)
    }

    @Test func parsesGatekeeper() {
        #expect(CheckupParsers.gatekeeperEnabled(Samples.gatekeeperOn) == true)
        #expect(CheckupParsers.gatekeeperEnabled(Samples.gatekeeperOff) == false)
        #expect(CheckupParsers.gatekeeperEnabled("") == nil)
    }

    @Test func parsesFileVault() {
        #expect(CheckupParsers.fileVault(Samples.fileVaultOn) == .on)
        #expect(CheckupParsers.fileVault(Samples.fileVaultOff) == .off)
        #expect(CheckupParsers.fileVault(Samples.fileVaultEncrypting) == .encrypting("37.4 %"))
        #expect(CheckupParsers.fileVault(Samples.fileVaultDecrypting) == .decrypting("12.0 %"))
        #expect(CheckupParsers.fileVault(Samples.fileVaultDeferred) == .deferred)
        #expect(CheckupParsers.fileVault("Error: something else") == nil)
    }

    @Test func parsesFirewall() {
        #expect(CheckupParsers.firewall(Samples.firewallOn) == .on)
        #expect(CheckupParsers.firewall(Samples.firewallOff) == .off)
        #expect(CheckupParsers.firewall(Samples.firewallBlockAll) == .blockAll)
        #expect(CheckupParsers.firewall("Firewall is disabled.") == .off)
        #expect(CheckupParsers.stealthMode(Samples.stealthOn) == true)
        #expect(CheckupParsers.stealthMode(Samples.stealthOff) == false)
        #expect(CheckupParsers.stealthMode(Samples.stealthOldOn) == true)
        #expect(CheckupParsers.stealthMode("nothing") == nil)
    }

    @Test func parsesEnrollment() throws {
        let none = try #require(CheckupParsers.enrollment(Samples.notEnrolled))
        #expect(!none.enrolled)
        #expect(!none.viaDEP)
        let managed = try #require(CheckupParsers.enrollment(Samples.enrolled))
        #expect(managed.enrolled)
        #expect(managed.viaDEP)
        #expect(managed.userApproved)
        #expect(managed.server == "mdm.example.com")
        #expect(CheckupParsers.enrollment("profiles: unknown option") == nil)
    }

    @Test func recognizesRootRefusals() {
        #expect(CheckupParsers.needsRoot(ToolOutput(status: 1, output: "", errorOutput: "This command must be run as root.")))
        #expect(!CheckupParsers.needsRoot(ToolOutput(output: Samples.fileVaultOn)))
    }

    @Test func readsPreferenceBooleans() {
        #expect(CheckupParsers.bool(true) == true)
        #expect(CheckupParsers.bool(0) == false)
        #expect(CheckupParsers.bool("YES") == true)
        #expect(CheckupParsers.bool(nil) == nil)
        #expect(CheckupParsers.bool("maybe") == nil)
    }

    @Test func managedUpdateSettingsWin() {
        let settings = CheckupParsers.updateSettings(
            softwareUpdate: ["AutomaticCheckEnabled": true, "CriticalUpdateInstall": true, "AutomaticallyInstallMacOSUpdates": false],
            commerce: ["AutoUpdate": true],
            managedSoftwareUpdate: ["AutomaticallyInstallMacOSUpdates": true]
        )
        #expect(settings.check == true)
        #expect(settings.installMacOS == true)
        #expect(settings.download == nil)
        #expect(settings.installAppUpdates == true)
        #expect(settings.installsSecurityResponses)
        #expect(!CheckupParsers.UpdateSettings(installConfigData: false).installsSecurityResponses)
    }

    @Test func comparesXProtectVersions() {
        #expect(CheckupParsers.isNewer("5287", than: "999"))
        #expect(!CheckupParsers.isNewer("5272", than: "5287"))
        #expect(CheckupParsers.xprotectVersion(["CFBundleShortVersionString": "5287"]) == "5287")
        #expect(CheckupParsers.xprotectVersion([:]) == nil)
    }
}

@Suite struct CheckupEvaluationTests {
    @Test func sipVerdicts() {
        #expect(SecurityCheckup.sip(ToolOutput(output: Samples.sipEnabled)).status == .pass)
        #expect(SecurityCheckup.sip(ToolOutput(output: Samples.sipDisabled)).status == .fail)
        let custom = SecurityCheckup.sip(ToolOutput(output: Samples.sipCustom))
        #expect(custom.status == .warning)
        #expect(custom.finding.contains("Kext Signing"))
        #expect(SecurityCheckup.sip(nil).status == .unknown)
        #expect(SecurityCheckup.sip(ToolOutput(output: "", timedOut: true)).status == .unknown)
    }

    @Test func rootOnlyToolsAreUnknownNotEscalated() {
        let refused = ToolOutput(status: 1, output: "", errorOutput: "fdesetup: This tool needs to be run as root.")
        let result = SecurityCheckup.fileVault(refused)
        #expect(result.status == .unknown)
        #expect(result.finding.contains("needs the helper"))
    }

    @Test func fileVaultAndGatekeeperVerdicts() {
        #expect(SecurityCheckup.fileVault(ToolOutput(output: Samples.fileVaultOn)).status == .pass)
        #expect(SecurityCheckup.fileVault(ToolOutput(output: Samples.fileVaultEncrypting)).status == .pass)
        #expect(SecurityCheckup.fileVault(ToolOutput(output: Samples.fileVaultDeferred)).status == .warning)
        #expect(SecurityCheckup.fileVault(ToolOutput(output: Samples.fileVaultDecrypting)).status == .fail)
        #expect(SecurityCheckup.fileVault(ToolOutput(output: Samples.fileVaultOff)).status == .fail)
        // spctl exits with 1 when assessments are disabled; the text still decides.
        #expect(SecurityCheckup.gatekeeper(ToolOutput(status: 1, output: Samples.gatekeeperOff)).status == .fail)
        #expect(SecurityCheckup.gatekeeper(ToolOutput(output: Samples.gatekeeperOn)).status == .pass)
    }

    @Test func firewallVerdicts() {
        let on = SecurityCheckup.firewall(ToolOutput(output: Samples.firewallOn), stealth: ToolOutput(output: Samples.stealthOff))
        #expect(on.status == .pass)
        #expect(on.finding.contains("stealth mode off"))
        #expect(SecurityCheckup.firewall(ToolOutput(output: Samples.firewallOff), stealth: nil).status == .warning)
        #expect(SecurityCheckup.firewall(ToolOutput(output: "garbage"), stealth: nil).status == .unknown)
    }

    @Test func updateVerdicts() {
        let all = CheckupParsers.UpdateSettings(check: true, download: true, installMacOS: true, installSecurity: true,
                                                installConfigData: true, installAppUpdates: true)
        #expect(SecurityCheckup.automaticUpdates(all).status == .pass)
        // Keys macOS leaves unset default to on, except installing macOS updates.
        #expect(SecurityCheckup.automaticUpdates(.init(installMacOS: true)).status == .pass)
        #expect(SecurityCheckup.automaticUpdates(.init()).status == .warning)
        #expect(SecurityCheckup.automaticUpdates(.init(installMacOS: true, installSecurity: false)).status == .fail)
        #expect(SecurityCheckup.automaticUpdates(.init(check: false, installMacOS: true)).status == .fail)
    }

    @Test func xprotectDependsOnSecurityResponses() {
        let info = SecurityCheckup.XProtectInfo(version: "5287", date: nil)
        #expect(SecurityCheckup.xprotect(info, updates: .init()).status == .pass)
        #expect(SecurityCheckup.xprotect(info, updates: .init(installSecurity: false)).status == .warning)
        #expect(SecurityCheckup.xprotect(nil, updates: .init()).status == .unknown)
    }

    @Test func sharingVerdicts() {
        let output = ToolOutput(output: Samples.overrides)
        #expect(SecurityCheckup.remoteLogin(output).status == .warning)
        #expect(SecurityCheckup.screenSharing(output, remoteManagement: nil).status == .pass)
        #expect(SecurityCheckup.screenSharing(output, remoteManagement: "enabled\n").status == .warning)
        let files = SecurityCheckup.sharingService(output, id: "file-sharing", title: "File Sharing",
                                                   label: "com.apple.smbd", whenOn: "On.")
        #expect(files.status == .warning)
        // Not listed: the plist's default, off.
        let absent = ToolOutput(output: "disabled services = {\n}\n")
        #expect(SecurityCheckup.remoteLogin(absent).status == .pass)
        // An empty or failed answer is not "everything off".
        #expect(SecurityCheckup.remoteLogin(ToolOutput(output: "")).status == .unknown)
        #expect(SecurityCheckup.remoteLogin(ToolOutput(status: 1, output: Samples.overrides)).status == .unknown)
        #expect(SecurityCheckup.remoteLogin(nil).status == .unknown)
    }

    @Test func loginWindowVerdicts() {
        #expect(SecurityCheckup.automaticLogin(.missing, kcpasswordExists: false).status == .pass)
        #expect(SecurityCheckup.automaticLogin(.missing, kcpasswordExists: true).status == .fail)
        let auto = SecurityCheckup.automaticLogin(.dictionary(["autoLoginUser": "alex"]), kcpasswordExists: false)
        #expect(auto.status == .fail)
        #expect(auto.finding.contains("alex"))
        #expect(SecurityCheckup.automaticLogin(.unreadable, kcpasswordExists: false).status == .unknown)
        #expect(SecurityCheckup.guestAccount(.dictionary(["GuestEnabled": true])).status == .warning)
        #expect(SecurityCheckup.guestAccount(.dictionary(["GuestEnabled": false])).status == .pass)
        #expect(SecurityCheckup.guestAccount(.missing).status == .pass)
        // A switch left behind without the Guest user lets nobody in.
        #expect(SecurityCheckup.guestAccount(.dictionary(["GuestEnabled": true]), guestUserExists: false).status == .pass)
    }

    @Test func deviceManagementVerdicts() {
        #expect(SecurityCheckup.deviceManagement(ToolOutput(output: Samples.notEnrolled)).status == .pass)
        let managed = SecurityCheckup.deviceManagement(ToolOutput(output: Samples.enrolled))
        #expect(managed.status == .warning)
        #expect(managed.finding.contains("mdm.example.com"))
    }

    @Test func pendingMacOSUpdates() throws {
        let now = Date()
        let offered = now.addingTimeInterval(-3 * 86_400)
        let plist: [String: Any] = [
            "LastSuccessfulDate": now,
            "FirstOfferDateDictionary": ["MSU_UPDATE_26A434_patch_27.0.1_minor": offered],
            "RecommendedUpdates": [
                ["Display Name": "Command Line Tools for Xcode 27.0", "Display Version": "27.0",
                 "Identifier": "Command Line Tools for Xcode 27.0"],
                ["Display Name": "macOS\u{a0}27.0.1", "Display Version": "27.0.1", "MobileSoftwareUpdate": true,
                 "Identifier": "MSU_UPDATE_26A434_patch_27.0.1_minor"],
            ],
        ]
        let status = try #require(CheckupParsers.updateStatus(plist))
        #expect(status.pending.map(\.name) == ["Command Line Tools for Xcode 27.0", "macOS 27.0.1"])
        #expect(status.pending.map(\.isMacOS) == [false, true])
        #expect(status.pending[1].offeredAt == offered)

        let waiting = SecurityCheckup.macOSUpdates(status, systemVersion: "27.0", now: now)
        #expect(waiting.status == .warning)
        #expect(waiting.finding.contains("macOS 27.0.1"))
        #expect(waiting.finding.contains("Command Line Tools"))
        // Left aside for a month: a failure.
        #expect(SecurityCheckup.macOSUpdates(status, systemVersion: "27.0", now: now.addingTimeInterval(40 * 86_400)).status == .fail)

        let current = CheckupParsers.UpdateStatus(pending: [], lastCheck: now)
        #expect(SecurityCheckup.macOSUpdates(current, systemVersion: "27.0", now: now).status == .pass)
        let stale = CheckupParsers.UpdateStatus(pending: [], lastCheck: now.addingTimeInterval(-30 * 86_400))
        #expect(SecurityCheckup.macOSUpdates(stale, systemVersion: "27.0", now: now).status == .warning)
        #expect(SecurityCheckup.macOSUpdates(nil, systemVersion: "27.0", now: now).status == .unknown)
        #expect(CheckupParsers.updateStatus(["AutomaticDownload": true]) == nil)
    }

    @Test func appStoreKeyIgnoredFromMacOS26() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hector-commerce-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Library/Preferences/com.apple.commerce.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["AutoUpdate": false], format: .binary, options: 0).write(to: url)
        let sequoia = SecurityCheckup(root: root, tools: .none, systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0))
        #expect(sequoia.gatherInputs().updates.installAppUpdates == false)
        let newer = SecurityCheckup(root: root, tools: .none, systemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        #expect(newer.gatherInputs().updates.installAppUpdates == nil)
    }

    @Test func settingsLinksUseOnlyTheSettingsScheme() throws {
        let link = try #require(SettingsPane.privacySecurity)
        let web = try #require(URL(string: "https://example.com"))
        #expect(SettingsPane.isSettingsLink(link))
        #expect(!SettingsPane.isSettingsLink(URL(fileURLWithPath: "/Applications/Calculator.app")))
        #expect(!SettingsPane.isSettingsLink(web))
    }
}

@Suite struct SecurityCheckupRunTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "hector-checkup-\(UUID().uuidString)")
        func plist(_ object: [String: Any], _ path: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0).write(to: url)
        }
        try plist(["AutomaticCheckEnabled": true, "AutomaticDownload": true, "CriticalUpdateInstall": true,
                   "ConfigDataInstall": true, "AutomaticallyInstallMacOSUpdates": true,
                   "RecommendedUpdates": [[String: Any]](), "LastSuccessfulDate": Date()],
                  "Library/Preferences/com.apple.SoftwareUpdate.plist")
        try plist(["AutoUpdate": true], "Library/Preferences/com.apple.commerce.plist")
        try plist(["GuestEnabled": false, "lastUserName": "alex"], "Library/Preferences/com.apple.loginwindow.plist")
        try plist(["CFBundleShortVersionString": "5287", "CFBundleIdentifier": "com.apple.XProtectFramework.XProtect"],
                  "Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")
        return root
    }

    @Test func runsEveryCheckReadOnly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firewall = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        let tools = CannedTools([
            "/usr/bin/csrutil status": ToolOutput(output: Samples.sipEnabled),
            "/usr/sbin/spctl --status": ToolOutput(output: Samples.gatekeeperOn),
            "/usr/bin/fdesetup status": ToolOutput(output: Samples.fileVaultOn),
            "\(firewall) --getglobalstate": ToolOutput(output: Samples.firewallOff),
            "\(firewall) --getstealthmode": ToolOutput(output: Samples.stealthOff),
            "/bin/launchctl print-disabled system": ToolOutput(output: "disabled services = {\n\t\"com.openssh.sshd\" => disabled\n}\n"),
            "/usr/bin/profiles status -type enrollment": ToolOutput(output: Samples.notEnrolled),
        ])
        let report = SecurityCheckup(root: root, tools: tools.runner).run()

        #expect(report.results.count == 14)
        #expect(Set(report.results.map(\.id)).count == 14)
        let byID = Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0) })
        #expect(byID[SecurityCheckup.CheckID.firewall]?.status == .warning)
        #expect(byID[SecurityCheckup.CheckID.xprotect]?.finding.contains("5287") == true)
        #expect(report.passedCount == 13)
        #expect(report.summary == "13 of 14 checks pass")
        // Only the fixed, read-only commands were run.
        #expect(Set(tools.invoked) == Set(tools.answers.keys))
        // Every fix has text, and every link opens System Settings only.
        for result in report.results {
            #expect(!result.howToFix.isEmpty)
            if let url = result.settingsURL { #expect(SettingsPane.isSettingsLink(url)) }
        }
    }

    @Test func missingToolsGiveUnknownNotPass() {
        let root = FileManager.default.temporaryDirectory.appending(path: "hector-checkup-empty-\(UUID().uuidString)")
        let report = SecurityCheckup(root: root, tools: .none).run()
        let toolChecks = [SecurityCheckup.CheckID.sip, SecurityCheckup.CheckID.gatekeeper, SecurityCheckup.CheckID.fileVault,
                          SecurityCheckup.CheckID.firewall, SecurityCheckup.CheckID.remoteLogin,
                          SecurityCheckup.CheckID.deviceManagement, SecurityCheckup.CheckID.xprotect]
        for id in toolChecks {
            #expect(report.results.first { $0.id == id }?.status == .unknown)
        }
    }

    @Test func reportRoundTripsAsJSON() throws {
        let report = SecurityCheckup(root: URL(fileURLWithPath: "/nonexistent-hector"), tools: .none).run()
        let data = try JSONEncoder.hector.encode(report)
        let decoded = try JSONDecoder.hector.decode(CheckupReport.self, from: data)
        #expect(decoded.results == report.results)
    }
}
