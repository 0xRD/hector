import Darwin
import Foundation

/// Reviews the Mac's main security settings: SIP, Gatekeeper, XProtect, kernel extensions,
/// FileVault, the screen lock, the firewall, automatic updates, pending macOS updates, sharing
/// services, AirDrop, automatic login, the guest account, Find My, MDM enrollment and Lockdown Mode.
///
/// Read-only by design: it runs Apple's own tools by absolute path with fixed argument arrays
/// (never through a shell, never a path found on disk) and reads world-readable preference files.
/// It never asks for a password and never needs root; a setting that only root can read is
/// reported as unknown rather than escalated.
public struct SecurityCheckup: Sendable {
    /// The system tools the checkup runs. All of them only report state.
    enum Command: CaseIterable, Sendable {
        case sip
        case gatekeeper
        case fileVault
        case firewall
        case stealthMode
        case launchdOverrides
        case enrollment
        case screenLock
        case kernelExtensions

        var executable: String {
            switch self {
            case .sip: "/usr/bin/csrutil"
            case .gatekeeper: "/usr/sbin/spctl"
            case .fileVault: "/usr/bin/fdesetup"
            case .firewall, .stealthMode: "/usr/libexec/ApplicationFirewall/socketfilterfw"
            case .launchdOverrides: "/bin/launchctl"
            case .enrollment: "/usr/bin/profiles"
            case .screenLock: "/usr/sbin/sysadminctl"
            case .kernelExtensions: "/usr/bin/kmutil"
            }
        }

        var arguments: [String] {
            switch self {
            case .sip: ["status"]
            case .gatekeeper: ["--status"]
            case .fileVault: ["status"]
            case .firewall: ["--getglobalstate"]
            case .stealthMode: ["--getstealthmode"]
            // Which launchd services were turned on or off: the sharing switches end up here.
            case .launchdOverrides: ["print-disabled", "system"]
            // `status` only reads local state; `show -type enrollment` would contact Apple.
            case .enrollment: ["status", "-type", "enrollment"]
            // The current user's setting; no password is asked for `status`.
            case .screenLock: ["-screenLock", "status"]
            // Lists what is loaded; the variant only silences a note on standard error.
            case .kernelExtensions: ["showloaded", "--list-only", "--variant-suffix", "release"]
            }
        }

        var toolName: String {
            switch self {
            case .sip: "csrutil"
            case .gatekeeper: "spctl"
            case .fileVault: "fdesetup"
            case .firewall, .stealthMode: "socketfilterfw"
            case .launchdOverrides: "launchctl"
            case .enrollment: "profiles"
            case .screenLock: "sysadminctl"
            case .kernelExtensions: "kmutil"
            }
        }
    }

    /// Stable check identifiers, in display order.
    public enum CheckID {
        public static let sip = "sip"
        public static let gatekeeper = "gatekeeper"
        public static let xprotect = "xprotect"
        public static let kernelExtensions = "kernel-extensions"
        public static let fileVault = "filevault"
        public static let screenLock = "screen-lock"
        public static let firewall = "firewall"
        public static let automaticUpdates = "automatic-updates"
        public static let macOSUpdates = "macos-updates"
        public static let remoteLogin = "remote-login"
        public static let screenSharing = "screen-sharing"
        public static let fileSharing = "file-sharing"
        public static let remoteAppleEvents = "remote-apple-events"
        public static let airDrop = "airdrop"
        public static let automaticLogin = "automatic-login"
        public static let guestAccount = "guest-account"
        public static let findMy = "find-my"
        public static let deviceManagement = "device-management"
        public static let lockdownMode = "lockdown-mode"
    }

    /// Prefix for system paths such as `/Library/Preferences`; `/` on a real Mac. Injectable so
    /// tests can use a folder of fixtures.
    public var root: URL
    /// The home folder whose preferences are read (AirDrop, Lockdown Mode): the user's own,
    /// or under `sudo` the one of the user who ran it. Injectable for tests.
    public var home: URL
    public var tools: ToolRunner
    /// The macOS version the settings belong to. Injectable for tests.
    public var systemVersion: OperatingSystemVersion
    /// Whether a local user exists. Injectable for tests.
    public var userExists: @Sendable (String) -> Bool

    public init(root: URL = URL(fileURLWithPath: "/"), home: URL = SecurityCheckup.userHome, tools: ToolRunner = .live,
                systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                userExists: @escaping @Sendable (String) -> Bool = { getpwnam($0) != nil }) {
        self.root = root
        self.home = home
        self.tools = tools
        self.systemVersion = systemVersion
        self.userExists = userExists
    }

    /// The logged-in user's home, also under `sudo` (whose own home is root's).
    public static var userHome: URL {
        if geteuid() == 0, let name = ProcessInfo.processInfo.environment["SUDO_USER"], let entry = getpwnam(name),
           let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public func run() -> CheckupReport {
        let start = Date()
        let inputs = gatherInputs()
        return CheckupReport(checkedAt: start, duration: Date().timeIntervalSince(start), ranAsRoot: geteuid() == 0,
                             results: Self.evaluate(inputs))
    }

    // MARK: - Inputs

    /// What a preference file gave.
    enum FileRead {
        case missing
        /// Present but not readable as this user, or not a property list.
        case unreadable
        case dictionary([String: Any])

        var values: [String: Any]? {
            if case .dictionary(let value) = self { return value }
            return nil
        }
    }

    struct XProtectInfo: Equatable {
        var version: String
        var date: Date?
    }

    /// Everything the checks look at, gathered first so the evaluation is a pure function.
    struct Inputs {
        var outputs: [Command: ToolOutput] = [:]
        var updates = CheckupParsers.UpdateSettings()
        /// `nil` when Software Update's state could not be read.
        var updateStatus: CheckupParsers.UpdateStatus?
        /// "27.0", for the update check's finding.
        var systemVersion = ""
        var now = Date()
        var xprotect: XProtectInfo?
        var loginWindow: FileRead = .missing
        /// `/etc/kcpassword` holds the automatic login password; it exists only while automatic
        /// login is on. Only root can read it, but anyone can see that it exists.
        var kcpasswordExists = false
        /// The Guest user record. "Allow guests to log in" creates it and removing the switch
        /// deletes it; `GuestEnabled` alone can stay behind after the guest was turned off.
        var guestUserExists = true
        /// Contents of the Remote Management state file, when present.
        var remoteManagement: String?
        /// /Library/Preferences/com.apple.FindMyMac.plist, world-readable.
        var findMyMac: FileRead = .missing
        /// The user's com.apple.sharingd (AirDrop).
        var sharingd: FileRead = .missing
        /// The user's global preferences (Lockdown Mode).
        var globalPreferences: FileRead = .missing
    }

    func gatherInputs() -> Inputs {
        var inputs = Inputs()
        inputs.outputs = runTools()

        let softwareUpdate = readPlist("Library/Preferences/com.apple.SoftwareUpdate.plist").values
        // From macOS 26 the App Store's automatic updates are a setting of the App Store app,
        // no longer the `AutoUpdate` key of com.apple.commerce: a value left there by an older
        // macOS says nothing, so it is not read.
        let commerce = systemVersion.majorVersion >= 26 ? nil : readPlist("Library/Preferences/com.apple.commerce.plist").values
        let managedSoftwareUpdate = readPlist("Library/Managed Preferences/com.apple.SoftwareUpdate.plist").values
        let managedCommerce = readPlist("Library/Managed Preferences/com.apple.commerce.plist").values
        inputs.updates = CheckupParsers.updateSettings(softwareUpdate: softwareUpdate, commerce: commerce,
                                                       managedSoftwareUpdate: managedSoftwareUpdate,
                                                       managedCommerce: managedCommerce)
        inputs.updateStatus = CheckupParsers.updateStatus(softwareUpdate)
        inputs.systemVersion = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
            .enumerated().filter { $0.offset < 2 || $0.element > 0 }.map { String($0.element) }.joined(separator: ".")
        inputs.xprotect = readXProtect()
        inputs.loginWindow = readPlist("Library/Preferences/com.apple.loginwindow.plist")
        inputs.kcpasswordExists = FileManager.default.fileExists(atPath: path("etc/kcpassword"))
        inputs.guestUserExists = userExists("Guest")
        let managementFile = path("Library/Application Support/Apple/Remote Desktop/RemoteManagement.launchd")
        inputs.remoteManagement = try? String(contentsOfFile: managementFile, encoding: .utf8)
        inputs.findMyMac = readPlist("Library/Preferences/com.apple.FindMyMac.plist")
        inputs.sharingd = readPlist(home.appending(path: "Library/Preferences/com.apple.sharingd.plist").path)
        inputs.globalPreferences = readPlist(home.appending(path: "Library/Preferences/.GlobalPreferences.plist").path)
        return inputs
    }

    /// Runs every tool at once: each is quick, but `profiles` and `fdesetup` can take a second.
    private func runTools() -> [Command: ToolOutput] {
        let commands = Command.allCases
        let collected = OutputCollector()
        let tools = self.tools
        DispatchQueue.concurrentPerform(iterations: commands.count) { index in
            let command = commands[index]
            if let output = tools.run(command.executable, command.arguments) {
                collected.set(output, for: command)
            }
        }
        return collected.outputs
    }

    private func path(_ relative: String) -> String {
        root.appending(path: relative).path
    }

    /// Reads a property list under `root`, or at an absolute path.
    private func readPlist(_ relative: String) -> FileRead {
        let file = relative.hasPrefix("/") ? relative : path(relative)
        guard FileManager.default.fileExists(atPath: file) else { return .missing }
        guard let data = FileManager.default.contents(atPath: file),
              let dictionary = CheckupParsers.dictionary(data) else { return .unreadable }
        return .dictionary(dictionary)
    }

    /// The newest of the two XProtect bundles: the one in `/Library/Apple` that Software Update
    /// installs, and the one macOS 15 keeps updated on its own in `/var/protected/xprotect`
    /// (often readable by root only, in which case it is skipped).
    private func readXProtect() -> XProtectInfo? {
        let candidates = [
            "Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist",
            "private/var/protected/xprotect/XProtect.bundle/Contents/Info.plist",
        ]
        var best: XProtectInfo?
        for candidate in candidates {
            guard let version = CheckupParsers.xprotectVersion(readPlist(candidate).values) else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path(candidate))
            let info = XProtectInfo(version: version, date: attributes?[.modificationDate] as? Date)
            if best == nil || CheckupParsers.isNewer(version, than: best?.version ?? "") { best = info }
        }
        return best
    }

    // MARK: - Evaluation

    static func evaluate(_ inputs: Inputs) -> [CheckResult] {
        let launchd = inputs.outputs[.launchdOverrides]
        return [
            sip(inputs.outputs[.sip]),
            gatekeeper(inputs.outputs[.gatekeeper]),
            xprotect(inputs.xprotect, updates: inputs.updates),
            kernelExtensions(inputs.outputs[.kernelExtensions]),
            fileVault(inputs.outputs[.fileVault]),
            screenLock(inputs.outputs[.screenLock]),
            firewall(inputs.outputs[.firewall], stealth: inputs.outputs[.stealthMode]),
            automaticUpdates(inputs.updates),
            macOSUpdates(inputs.updateStatus, systemVersion: inputs.systemVersion, now: inputs.now),
            remoteLogin(launchd),
            screenSharing(launchd, remoteManagement: inputs.remoteManagement),
            sharingService(launchd, id: CheckID.fileSharing, title: "File Sharing", label: "com.apple.smbd",
                           whenOn: "On: folders of this Mac are shared over the network (SMB)."),
            sharingService(launchd, id: CheckID.remoteAppleEvents, title: "Remote Apple Events", label: "com.apple.AEServer",
                           whenOn: "On: apps on other Macs can send Apple events to this one."),
            airDrop(inputs.sharingd),
            automaticLogin(inputs.loginWindow, kcpasswordExists: inputs.kcpasswordExists),
            guestAccount(inputs.loginWindow, guestUserExists: inputs.guestUserExists),
            findMy(inputs.findMyMac),
            deviceManagement(inputs.outputs[.enrollment]),
            lockdownMode(inputs.globalPreferences),
        ]
    }

    /// Why a tool's output cannot be used, as a finding; `nil` when it can.
    private static func problem(_ output: ToolOutput?, _ command: Command) -> String? {
        guard let output else { return "Unknown: \(command.toolName) could not be run." }
        if output.timedOut { return "Unknown: \(command.toolName) did not answer in time." }
        if CheckupParsers.needsRoot(output) { return "Unknown: needs the helper (only root can read this)." }
        return nil
    }

    /// Some tools print their verdict on standard error.
    private static func text(_ output: ToolOutput?) -> String {
        guard let output else { return "" }
        return output.output + "\n" + output.errorOutput
    }

    private static func unexpected(_ command: Command) -> String {
        "Unknown: unexpected \(command.toolName) output."
    }

    static func sip(_ output: ToolOutput?) -> CheckResult {
        let fix = "Start up in macOS Recovery, choose Utilities → Terminal, run `csrutil enable`, then restart."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.sip, title: "System Integrity Protection", status: status, finding: finding, howToFix: fix)
        }
        if let issue = problem(output, .sip) { return result(.unknown, issue) }
        switch CheckupParsers.sip(text(output)) {
        case .enabled?:
            return result(.pass, "On: system files and Apple's processes are protected, even from root.")
        case .disabled?:
            return result(.fail, "Off: malware running as root can change macOS itself.")
        case .custom(let protections)?:
            let list = protections.isEmpty ? "" : ": \(protections.joined(separator: ", ")) off"
            return result(.warning, "Partly off (custom configuration)\(list).")
        case nil:
            return result(.unknown, unexpected(.sip))
        }
    }

    static func gatekeeper(_ output: ToolOutput?) -> CheckResult {
        let fix = "System Settings → Privacy & Security → Security → Allow applications from “App Store & Known Developers”. "
            + "If that choice is missing, run `sudo spctl --global-enable` in Terminal."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.gatekeeper, title: "Gatekeeper", status: status, finding: finding, howToFix: fix,
                        settingsURL: SettingsPane.privacySecurity)
        }
        if let issue = problem(output, .gatekeeper) { return result(.unknown, issue) }
        switch CheckupParsers.gatekeeperEnabled(text(output)) {
        case true?: return result(.pass, "On: downloaded apps must be signed and notarized, or approved by you once.")
        case false?: return result(.fail, "Off: any downloaded app opens without a check.")
        case nil: return result(.unknown, unexpected(.gatekeeper))
        }
    }

    static func xprotect(_ info: XProtectInfo?, updates: CheckupParsers.UpdateSettings) -> CheckResult {
        let fix = "XProtect updates itself while “Install Security Responses and system files” is on: "
            + "System Settings → General → Software Update → Automatic Updates (ⓘ)."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.xprotect, title: "XProtect", status: status, finding: finding, howToFix: fix,
                        settingsURL: SettingsPane.softwareUpdate)
        }
        guard let info else { return result(.unknown, "Unknown: XProtect's version could not be read.") }
        var version = "Version \(info.version)"
        if let date = info.date { version += ", installed \(Display.day(date))" }
        guard updates.installsSecurityResponses else {
            return result(.warning, "\(version), but security data files are not installed automatically, so it may be out of date.")
        }
        return result(.pass, "\(version). Apple's built-in malware signatures update automatically.")
    }

    static func fileVault(_ output: ToolOutput?) -> CheckResult {
        let fix = "System Settings → Privacy & Security → FileVault → Turn On…, and keep the recovery key somewhere safe."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.fileVault, title: "FileVault", status: status, finding: finding, howToFix: fix,
                        settingsURL: SettingsPane.privacySecurity)
        }
        if let issue = problem(output, .fileVault) { return result(.unknown, issue) }
        switch CheckupParsers.fileVault(text(output)) {
        case .on?:
            return result(.pass, "On: the disk is encrypted and unreadable without your password.")
        case .encrypting(let percent)?:
            return result(.pass, "On, still encrypting the disk" + (percent.map { " (\($0) done)." } ?? "."))
        case .deferred?:
            return result(.warning, "Turned on, but encryption starts only at the next login or restart.")
        case .decrypting(let percent)?:
            return result(.fail, "Being turned off: the disk is being decrypted" + (percent.map { " (\($0) done)." } ?? "."))
        case .off?:
            return result(.fail, "Off: anyone holding this Mac can read the disk.")
        case nil:
            return result(.unknown, unexpected(.fileVault))
        }
    }

    /// Third-party kernel extensions run inside the kernel, with no sandbox: one bug or one
    /// malicious update owns the Mac. System extensions and DriverKit replace most of them.
    static func kernelExtensions(_ output: ToolOutput?) -> CheckResult {
        let fix = "Remove the app that installed it if you no longer use it, or update it to a version that uses a system "
            + "extension. Allowed extensions are listed in System Settings → General → Login Items & Extensions."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.kernelExtensions, title: "Kernel extensions", status: status, finding: finding,
                        howToFix: fix, settingsURL: SettingsPane.loginItems)
        }
        if let issue = problem(output, .kernelExtensions) { return result(.unknown, issue) }
        guard let found = CheckupParsers.thirdPartyKernelExtensions(text(output)) else {
            return result(.unknown, unexpected(.kernelExtensions))
        }
        if found.isEmpty { return result(.pass, "None from other developers: only Apple's code runs in the kernel.") }
        let shown = Display.list(Array(found.prefix(4)) + (found.count > 4 ? ["\(found.count - 4) more"] : []))
        let one = found.count == 1
        return result(.warning, "\(found.count) from other developers \(one ? "is" : "are") loaded (\(shown)): "
            + "\(one ? "it runs" : "they run") with the kernel's full rights.")
    }

    /// How soon a password is asked once the screen saver starts or the display sleeps.
    static func screenLock(_ output: ToolOutput?) -> CheckResult {
        let fix = "System Settings → Lock Screen → “Require password after screen saver begins or display is turned off”: "
            + "Immediately, or within 5 minutes."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.screenLock, title: "Screen lock", status: status, finding: finding, howToFix: fix,
                        settingsURL: SettingsPane.lockScreen)
        }
        if let issue = problem(output, .screenLock) { return result(.unknown, issue) }
        switch CheckupParsers.screenLock(text(output)) {
        case .immediate?:
            return result(.pass, "A password is asked as soon as the screen saver starts or the display sleeps.")
        case .after(let seconds)?:
            let delay = delayText(seconds)
            return seconds <= 300
                ? result(.pass, "A password is asked \(delay) after the screen saver starts or the display sleeps.")
                : result(.warning, "A password is asked only \(delay) after the screen saver starts: anyone at the desk "
                    + "meanwhile gets in.")
        case .off?:
            return result(.fail, "Off: waking this Mac from sleep or the screen saver needs no password.")
        case nil:
            return result(.unknown, unexpected(.screenLock))
        }
    }

    /// "5 seconds", "1 minute", "8 hours": the choices System Settings offers.
    static func delayText(_ seconds: Int) -> String {
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        if seconds >= 3600, seconds % 3600 == 0 { return unit(seconds / 3600, "hour") }
        if seconds >= 60, seconds % 60 == 0 { return unit(seconds / 60, "minute") }
        return unit(seconds, "second")
    }

    static func firewall(_ output: ToolOutput?, stealth: ToolOutput?) -> CheckResult {
        let fix = "System Settings → Network → Firewall → turn it on. Under Options…, “Enable stealth mode” also stops "
            + "this Mac from answering pings and port scans."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.firewall, title: "Firewall", status: status, finding: finding, howToFix: fix,
                        settingsURL: SettingsPane.network)
        }
        if let issue = problem(output, .firewall) { return result(.unknown, issue) }
        let stealthOn = problem(stealth, .stealthMode) == nil ? CheckupParsers.stealthMode(text(stealth)) : nil
        let stealthNote: String
        switch stealthOn {
        case true?: stealthNote = ", stealth mode on"
        case false?: stealthNote = ", stealth mode off"
        case nil: stealthNote = ""
        }
        switch CheckupParsers.firewall(text(output)) {
        case .on?:
            return result(.pass, "On\(stealthNote): apps must be allowed before they accept incoming connections.")
        case .blockAll?:
            return result(.pass, "On, blocking all incoming connections\(stealthNote).")
        case .off?:
            // A warning, not a failure: macOS ships with it off, and with sharing off little listens.
            return result(.warning, "Off: any app that listens on the network can be reached from it.")
        case nil:
            return result(.unknown, unexpected(.firewall))
        }
    }

    static func automaticUpdates(_ settings: CheckupParsers.UpdateSettings) -> CheckResult {
        let fix = "System Settings → General → Software Update → Automatic Updates (ⓘ): turn every switch on, "
            + "at least “Install Security Responses and system files”."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.automaticUpdates, title: "Automatic updates", status: status, finding: finding,
                        howToFix: fix, settingsURL: SettingsPane.softwareUpdate)
        }
        // Missing keys mean macOS's defaults: checking, downloading and security responses are on.
        var serious: [String] = []
        if settings.check == false { serious.append("checking for updates") }
        if !settings.installsSecurityResponses { serious.append("installing Security Responses and system files") }
        var minor: [String] = []
        if settings.download == false { minor.append("downloading updates") }
        // No default worth trusting for this one: only an explicit "on" counts.
        if settings.installMacOS != true { minor.append("installing macOS updates") }
        if settings.installAppUpdates == false { minor.append("installing App Store app updates") }

        if !serious.isEmpty {
            return result(.fail, "Off: " + Display.list(serious + minor) + ".")
        }
        if !minor.isEmpty {
            return result(.warning, "Security responses install automatically. Still off: " + Display.list(minor) + ".")
        }
        return result(.pass, "macOS updates and security responses download and install automatically.")
    }

    /// Updates waiting in Software Update. A macOS update left aside for a month is a failure:
    /// the security fixes it carries are public by then.
    static func macOSUpdates(_ status: CheckupParsers.UpdateStatus?, systemVersion: String, now: Date) -> CheckResult {
        let fix = "System Settings → General → Software Update → Update Now (or Restart Now when it is downloaded)."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.macOSUpdates, title: "macOS up to date", status: status, finding: finding,
                        howToFix: fix, settingsURL: SettingsPane.softwareUpdate)
        }
        guard let status else { return result(.unknown, "Unknown: Software Update's state could not be read.") }
        let running = systemVersion.isEmpty ? "" : " (this Mac runs macOS \(systemVersion))"
        let macOS = status.pending.filter(\.isMacOS)
        let others = status.pending.filter { !$0.isMacOS }.map(\.name)
        let othersNote = others.isEmpty ? "" : " Also waiting: " + Display.list(others) + "."
        if !macOS.isEmpty {
            let names = Display.list(macOS.map(\.name))
            let oldest = macOS.compactMap(\.offeredAt).min()
            let days = oldest.map { Int(now.timeIntervalSince($0) / 86_400) } ?? 0
            let one = macOS.count == 1
            let available = oldest.map { (one ? "has" : "have") + " been available since \(Display.day($0))" } ?? (one ? "is available" : "are available")
            return result(days >= 30 ? .fail : .warning, "\(names) \(available)\(running), not installed yet.\(othersNote)")
        }
        if let lastCheck = status.lastCheck, now.timeIntervalSince(lastCheck) > 14 * 86_400 {
            return result(.warning, "No update was found, but Software Update has not checked since \(Display.day(lastCheck)).")
        }
        return result(.pass, "Up to date\(running).\(othersNote)")
    }

    /// `true` when launchd's overrides turn `label` on. Services absent from the list keep the
    /// default of their plist, which is off for every sharing service checked here.
    private static func isEnabled(_ label: String, in overrides: [String: Bool]) -> Bool {
        overrides[label] == false
    }

    private static func overrides(_ output: ToolOutput?) -> [String: Bool]? {
        guard problem(output, .launchdOverrides) == nil, let output, output.succeeded else { return nil }
        let text = output.output
        // An empty answer would read as "everything off"; insist on the tool's own framing.
        guard text.contains("disabled services") || text.contains("=>") else { return nil }
        return PersistenceParsers.disabledOverrides(text)
    }

    static func remoteLogin(_ output: ToolOutput?) -> CheckResult {
        let fix = "System Settings → General → Sharing → turn off Remote Login, unless you reach this Mac with SSH."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.remoteLogin, title: "Remote Login (SSH)", status: status, finding: finding,
                        howToFix: fix, settingsURL: SettingsPane.sharing)
        }
        guard let services = overrides(output) else {
            return result(.unknown, problem(output, .launchdOverrides) ?? unexpected(.launchdOverrides))
        }
        return isEnabled("com.openssh.sshd", in: services)
            ? result(.warning, "On: this Mac accepts SSH logins from the network.")
            : result(.pass, "Off.")
    }

    static func screenSharing(_ output: ToolOutput?, remoteManagement: String?) -> CheckResult {
        let fix = "System Settings → General → Sharing → turn off Screen Sharing and Remote Management, unless you use them."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.screenSharing, title: "Screen Sharing and Remote Management", status: status,
                        finding: finding, howToFix: fix, settingsURL: SettingsPane.sharing)
        }
        // Apple Remote Desktop's switch is recorded in its own file, which reads "enabled".
        let management = remoteManagement?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "enabled"
        if management {
            return result(.warning, "Remote Management is on: this Mac can be watched and controlled from the network.")
        }
        guard let services = overrides(output) else {
            return result(.unknown, problem(output, .launchdOverrides) ?? unexpected(.launchdOverrides))
        }
        return isEnabled("com.apple.screensharing", in: services)
            ? result(.warning, "Screen Sharing is on: this Mac's screen can be viewed and controlled from the network.")
            : result(.pass, "Off.")
    }

    static func sharingService(_ output: ToolOutput?, id: String, title: String, label: String, whenOn: String) -> CheckResult {
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: id, title: title, status: status, finding: finding,
                        howToFix: "System Settings → General → Sharing → turn off \(title), unless you use it.",
                        settingsURL: SettingsPane.sharing)
        }
        guard let services = overrides(output) else {
            return result(.unknown, problem(output, .launchdOverrides) ?? unexpected(.launchdOverrides))
        }
        return isEnabled(label, in: services) ? result(.warning, whenOn) : result(.pass, "Off.")
    }

    /// AirDrop open to everyone lets strangers nearby push files and pictures; recent macOS turns
    /// "Everyone" back to "Contacts Only" after 10 minutes, older versions keep it.
    static func airDrop(_ sharingd: FileRead) -> CheckResult {
        let fix = "Control Center → AirDrop, or Finder → Go → AirDrop → “Allow me to be discovered by”: Contacts Only, "
            + "or No One when you do not use it."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.airDrop, title: "AirDrop", status: status, finding: finding, howToFix: fix,
                        settingsURL: SettingsPane.airDrop)
        }
        if case .unreadable = sharingd { return result(.unknown, "Unknown: AirDrop's settings could not be read.") }
        let value = sharingd.values?["DiscoverableMode"]
        // Missing means the default since macOS 14: contacts only.
        guard value != nil else { return result(.pass, "Contacts Only: only people in your contacts can see this Mac.") }
        switch CheckupParsers.airDropMode(value) {
        case .off?: return result(.pass, "Off: this Mac cannot be seen with AirDrop.")
        case .contactsOnly?: return result(.pass, "Contacts Only: only people in your contacts can see this Mac.")
        case .everyone?: return result(.warning, "Everyone: anyone nearby can see this Mac and offer it files.")
        case nil: return result(.unknown, "Unknown: unexpected AirDrop setting.")
        }
    }

    static func automaticLogin(_ loginWindow: FileRead, kcpasswordExists: Bool) -> CheckResult {
        let fix = "System Settings → Users & Groups → “Automatically log in as”: Off. Turning FileVault on also turns it off."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.automaticLogin, title: "Automatic login", status: status, finding: finding,
                        howToFix: fix, settingsURL: SettingsPane.usersGroups)
        }
        let user: String = (loginWindow.values?["autoLoginUser"] as? String) ?? ""
        if !user.isEmpty {
            return result(.fail, "On as “\(user)”: anyone who starts this Mac is logged in without a password.")
        }
        if kcpasswordExists {
            return result(.fail, "On: anyone who starts this Mac is logged in without a password.")
        }
        if case .unreadable = loginWindow {
            return result(.unknown, "Unknown: the login window settings could not be read.")
        }
        return result(.pass, "Off: a password is needed after every start.")
    }

    static func guestAccount(_ loginWindow: FileRead, guestUserExists: Bool = true) -> CheckResult {
        let fix = "System Settings → Users & Groups → Guest User (ⓘ) → turn off “Allow guests to log in to this computer”."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.guestAccount, title: "Guest account", status: status, finding: finding,
                        howToFix: fix, settingsURL: SettingsPane.usersGroups)
        }
        if case .unreadable = loginWindow {
            return result(.unknown, "Unknown: the login window settings could not be read.")
        }
        // Missing means the default: off.
        guard CheckupParsers.bool(loginWindow.values?["GuestEnabled"]) == true else { return result(.pass, "Off.") }
        // The switch can outlive the account: without a Guest user, there is nobody to log in as.
        guard guestUserExists else { return result(.pass, "Off: there is no Guest user on this Mac.") }
        return result(.warning, "On: anyone can log in as Guest, without a password.")
    }

    /// Find My Mac also turns on Activation Lock: a stolen Mac cannot be erased and reused
    /// without the owner's Apple Account.
    static func findMy(_ findMyMac: FileRead) -> CheckResult {
        let fix = "System Settings → your name → iCloud → Find My Mac: On. It also turns on Activation Lock."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.findMy, title: "Find My Mac", status: status, finding: finding, howToFix: fix,
                        settingsURL: SettingsPane.appleAccount)
        }
        if case .unreadable = findMyMac { return result(.unknown, "Unknown: Find My's state could not be read.") }
        if CheckupParsers.bool(findMyMac.values?["FMMEnabled"]) == true {
            return result(.pass, "On: a lost Mac can be located, locked or erased, and Activation Lock stops a thief reusing it.")
        }
        return result(.warning, "Off: a lost or stolen Mac cannot be located, and anyone can erase and reuse it.")
    }

    /// Information only: Lockdown Mode is for people who may be personally targeted, so being
    /// off is never a problem.
    static func lockdownMode(_ globalPreferences: FileRead) -> CheckResult {
        let fix = "System Settings → Privacy & Security → Lockdown Mode. Meant for people who may be personally targeted "
            + "by sophisticated attacks; it turns off features that such attacks use."
        func result(_ finding: String) -> CheckResult {
            CheckResult(id: CheckID.lockdownMode, title: "Lockdown Mode", status: .pass, finding: finding, howToFix: fix,
                        settingsURL: SettingsPane.privacySecurity)
        }
        if CheckupParsers.bool(globalPreferences.values?["LDMGlobalEnabled"]) == true {
            return result("On: message attachments, web technologies and wired accessories are restricted.")
        }
        return result("Off, as on most Macs. Information only: worth turning on if you may be personally targeted.")
    }

    static func deviceManagement(_ output: ToolOutput?) -> CheckResult {
        let fix = "Expected on a work or school Mac. Otherwise, see who manages it in System Settings → General → "
            + "Device Management, and remove any profile you do not recognize."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.deviceManagement, title: "Device management (MDM)", status: status, finding: finding,
                        howToFix: fix, settingsURL: SettingsPane.deviceManagement)
        }
        if let issue = problem(output, .enrollment) { return result(.unknown, issue) }
        guard let enrollment = CheckupParsers.enrollment(text(output)) else { return result(.unknown, unexpected(.enrollment)) }
        guard enrollment.enrolled else { return result(.pass, "Not enrolled: no organization manages this Mac.") }
        var how: [String] = []
        if enrollment.viaDEP { how.append("assigned through Automated Device Enrollment") }
        if enrollment.userApproved { how.append("user approved") }
        var finding = "Enrolled: an organization can install profiles and apps, and change settings"
        if let server = enrollment.server { finding += " (server \(server))" }
        finding += how.isEmpty ? "." : "; " + how.joined(separator: ", ") + "."
        return result(.warning, finding)
    }
}

/// Collects tool outputs from `concurrentPerform`'s threads.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecurityCheckup.Command: ToolOutput] = [:]

    func set(_ output: ToolOutput, for command: SecurityCheckup.Command) {
        lock.withLock { values[command] = output }
    }

    var outputs: [SecurityCheckup.Command: ToolOutput] { lock.withLock { values } }
}
