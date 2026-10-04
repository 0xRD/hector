import Darwin
import Foundation

/// Reviews the Mac's main security settings: SIP, Gatekeeper, XProtect, FileVault, the firewall,
/// automatic updates, sharing services, automatic login, the guest account and MDM enrollment.
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

        var executable: String {
            switch self {
            case .sip: "/usr/bin/csrutil"
            case .gatekeeper: "/usr/sbin/spctl"
            case .fileVault: "/usr/bin/fdesetup"
            case .firewall, .stealthMode: "/usr/libexec/ApplicationFirewall/socketfilterfw"
            case .launchdOverrides: "/bin/launchctl"
            case .enrollment: "/usr/bin/profiles"
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
            }
        }
    }

    /// Stable check identifiers, in display order.
    public enum CheckID {
        public static let sip = "sip"
        public static let gatekeeper = "gatekeeper"
        public static let xprotect = "xprotect"
        public static let fileVault = "filevault"
        public static let firewall = "firewall"
        public static let automaticUpdates = "automatic-updates"
        public static let remoteLogin = "remote-login"
        public static let screenSharing = "screen-sharing"
        public static let fileSharing = "file-sharing"
        public static let remoteAppleEvents = "remote-apple-events"
        public static let automaticLogin = "automatic-login"
        public static let guestAccount = "guest-account"
        public static let deviceManagement = "device-management"
    }

    /// Prefix for system paths such as `/Library/Preferences`; `/` on a real Mac. Injectable so
    /// tests can use a folder of fixtures.
    public var root: URL
    public var tools: ToolRunner

    public init(root: URL = URL(fileURLWithPath: "/"), tools: ToolRunner = .live) {
        self.root = root
        self.tools = tools
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
        var xprotect: XProtectInfo?
        var loginWindow: FileRead = .missing
        /// `/etc/kcpassword` holds the automatic login password; it exists only while automatic
        /// login is on. Only root can read it, but anyone can see that it exists.
        var kcpasswordExists = false
        /// Contents of the Remote Management state file, when present.
        var remoteManagement: String?
    }

    func gatherInputs() -> Inputs {
        var inputs = Inputs()
        inputs.outputs = runTools()

        let softwareUpdate = readPlist("Library/Preferences/com.apple.SoftwareUpdate.plist").values
        let commerce = readPlist("Library/Preferences/com.apple.commerce.plist").values
        let managedSoftwareUpdate = readPlist("Library/Managed Preferences/com.apple.SoftwareUpdate.plist").values
        let managedCommerce = readPlist("Library/Managed Preferences/com.apple.commerce.plist").values
        inputs.updates = CheckupParsers.updateSettings(softwareUpdate: softwareUpdate, commerce: commerce,
                                                       managedSoftwareUpdate: managedSoftwareUpdate,
                                                       managedCommerce: managedCommerce)
        inputs.xprotect = readXProtect()
        inputs.loginWindow = readPlist("Library/Preferences/com.apple.loginwindow.plist")
        inputs.kcpasswordExists = FileManager.default.fileExists(atPath: path("etc/kcpassword"))
        let managementFile = path("Library/Application Support/Apple/Remote Desktop/RemoteManagement.launchd")
        inputs.remoteManagement = try? String(contentsOfFile: managementFile, encoding: .utf8)
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

    private func readPlist(_ relative: String) -> FileRead {
        let file = path(relative)
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
            fileVault(inputs.outputs[.fileVault]),
            firewall(inputs.outputs[.firewall], stealth: inputs.outputs[.stealthMode]),
            automaticUpdates(inputs.updates),
            remoteLogin(launchd),
            screenSharing(launchd, remoteManagement: inputs.remoteManagement),
            sharingService(launchd, id: CheckID.fileSharing, title: "File Sharing", label: "com.apple.smbd",
                           whenOn: "On: folders of this Mac are shared over the network (SMB)."),
            sharingService(launchd, id: CheckID.remoteAppleEvents, title: "Remote Apple Events", label: "com.apple.AEServer",
                           whenOn: "On: apps on other Macs can send Apple events to this one."),
            automaticLogin(inputs.loginWindow, kcpasswordExists: inputs.kcpasswordExists),
            guestAccount(inputs.loginWindow),
            deviceManagement(inputs.outputs[.enrollment]),
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

    static func guestAccount(_ loginWindow: FileRead) -> CheckResult {
        let fix = "System Settings → Users & Groups → Guest User (ⓘ) → turn off “Allow guests to log in to this computer”."
        func result(_ status: CheckResult.Status, _ finding: String) -> CheckResult {
            CheckResult(id: CheckID.guestAccount, title: "Guest account", status: status, finding: finding,
                        howToFix: fix, settingsURL: SettingsPane.usersGroups)
        }
        if case .unreadable = loginWindow {
            return result(.unknown, "Unknown: the login window settings could not be read.")
        }
        // Missing means the default: off.
        return CheckupParsers.bool(loginWindow.values?["GuestEnabled"]) == true
            ? result(.warning, "On: anyone can log in as Guest, without a password.")
            : result(.pass, "Off.")
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
