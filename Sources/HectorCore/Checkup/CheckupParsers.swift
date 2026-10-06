import Foundation

/// Pure parsers for what the checkup's tools print and the preference files it reads. Kept apart
/// from `SecurityCheckup` so they can be tested with sample output.
///
/// The tools run with `LC_ALL=C`, so their messages are in English. Every parser returns `nil` for
/// text it does not know rather than guessing: a wrong "pass" is worse
/// than an honest "unknown".
public enum CheckupParsers {
    // MARK: - csrutil status

    public enum SIPState: Equatable, Sendable {
        case enabled
        case disabled
        /// Partly disabled (`csrutil enable --without …`): the protections listed are off.
        case custom(disabledProtections: [String])
    }

    /// Parses `csrutil status`.
    public static func sip(_ text: String) -> SIPState? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("System Integrity Protection status:") }) else { return nil }
        let value = line.components(separatedBy: "status:").last?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let isCustom = value.contains("custom configuration") || value.hasPrefix("unknown")
        if isCustom {
            // "\tKext Signing: disabled" lines under "Configuration:". "Apple Internal" is off on
            // every Mac outside Apple, so it says nothing about this one.
            let disabled = text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.lowercased().hasSuffix(": disabled"), !line.contains("status:") else { return nil }
                let name = String(line.dropLast(": disabled".count))
                return name == "Apple Internal" ? nil : name
            }
            return .custom(disabledProtections: disabled)
        }
        if value.hasPrefix("enabled") { return .enabled }
        if value.hasPrefix("disabled") { return .disabled }
        return nil
    }

    // MARK: - spctl --status

    /// Parses `spctl --status`: `true` when Gatekeeper assessments are enabled.
    public static func gatekeeperEnabled(_ text: String) -> Bool? {
        let lower = text.lowercased()
        if lower.contains("assessments enabled") { return true }
        if lower.contains("assessments disabled") { return false }
        return nil
    }

    // MARK: - fdesetup status

    public enum FileVaultState: Equatable, Sendable {
        case on
        case off
        /// Turned on, still encrypting the disk.
        case encrypting(String?)
        /// Being turned off.
        case decrypting(String?)
        /// Turned on, takes effect at the next login or restart.
        case deferred
    }

    /// Parses `fdesetup status`.
    public static func fileVault(_ text: String) -> FileVaultState? {
        let lower = text.lowercased()
        if lower.contains("encryption in progress") { return .encrypting(percent(in: text)) }
        if lower.contains("decryption in progress") { return .decrypting(percent(in: text)) }
        if lower.contains("deferred enablement") || lower.contains("will be enabled after") { return .deferred }
        if lower.contains("filevault is on") { return .on }
        if lower.contains("filevault is off") { return .off }
        return nil
    }

    /// "Percent completed = 34.5" → "34.5 %".
    private static func percent(in text: String) -> String? {
        guard let range = text.range(of: "Percent completed = ") else { return nil }
        let number = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return number.isEmpty ? nil : "\(number) %"
    }

    // MARK: - socketfilterfw

    public enum FirewallState: Equatable, Sendable {
        case off
        case on
        /// "Block all incoming connections".
        case blockAll
    }

    /// Parses `socketfilterfw --getglobalstate`, such as "Firewall is enabled. (State = 1)".
    public static func firewall(_ text: String) -> FirewallState? {
        // The state number is the most precise part: 0 off, 1 on, 2 block all.
        if let range = text.range(of: "State = ") {
            switch text[range.upperBound...].first {
            case "0"?: return .off
            case "1"?: return .on
            case "2"?: return .blockAll
            default: break
            }
        }
        let lower = text.lowercased()
        if lower.contains("blocking all") { return .blockAll }
        if lower.contains("firewall is disabled") { return .off }
        if lower.contains("firewall is enabled") { return .on }
        return nil
    }

    /// Parses `socketfilterfw --getstealthmode`: "Firewall stealth mode is on" on recent macOS,
    /// "Stealth mode enabled" on older releases.
    public static func stealthMode(_ text: String) -> Bool? {
        let lower = text.lowercased()
        guard lower.contains("stealth") else { return nil }
        if lower.contains("is on") || lower.contains("enabled") { return true }
        if lower.contains("is off") || lower.contains("disabled") { return false }
        return nil
    }

    // MARK: - profiles status -type enrollment

    public struct Enrollment: Equatable, Sendable {
        public var enrolled: Bool
        /// Automated Device Enrollment (formerly DEP): the Mac was assigned to an organization.
        public var viaDEP: Bool
        public var userApproved: Bool
        /// Host name of the MDM server, when the tool prints it.
        public var server: String?
    }

    /// Parses `profiles status -type enrollment`:
    ///
    ///     Enrolled via DEP: No
    ///     MDM enrollment: Yes (User Approved)
    public static func enrollment(_ text: String) -> Enrollment? {
        var dep: Bool?
        var mdm: Bool?
        var approved = false
        var server: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let yes = value.lowercased().hasPrefix("yes")
            if key == "enrolled via dep" {
                dep = yes
            } else if key == "mdm enrollment" {
                mdm = yes
                approved = value.lowercased().contains("user approved")
            } else if key == "mdm server" {
                server = URL(string: value)?.host ?? (value.isEmpty ? nil : value)
            }
        }
        guard let mdm else { return nil }
        return Enrollment(enrolled: mdm, viaDEP: dep ?? false, userApproved: approved, server: server)
    }

    // MARK: - Root

    /// The tool refused to run without root.
    public static func needsRoot(_ output: ToolOutput) -> Bool {
        let text = (output.output + "\n" + output.errorOutput).lowercased()
        return ["must be run as root", "requires root", "needs to be run as root", "run as root",
                "requires administrator", "superuser"].contains { text.contains($0) }
    }

    // MARK: - Preferences

    /// A Boolean preference as written by System Settings or by a profile: `<true/>`, `1`, `"YES"`.
    public static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: return bool
        case let number as Int: return number != 0
        case let string as String:
            switch string.lowercased() {
            case "1", "yes", "true": return true
            case "0", "no", "false": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Reads a property list into a dictionary; `nil` when missing or unreadable.
    public static func dictionary(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The automatic update switches of System Settings → General → Software Update →
    /// Automatic Updates. `nil` means the key is not set, which macOS reads as its default.
    public struct UpdateSettings: Equatable, Sendable {
        /// "Check for updates" (`AutomaticCheckEnabled`, on by default).
        public var check: Bool?
        /// "Download new updates when available" (`AutomaticDownload`, on by default).
        public var download: Bool?
        /// "Install macOS updates" (`AutomaticallyInstallMacOSUpdates`).
        public var installMacOS: Bool?
        /// "Install Security Responses and system files" (`CriticalUpdateInstall`, on by
        /// default): XProtect, the malware removal tool and Rapid Security Responses.
        public var installSecurity: Bool?
        /// The older key for the same data files (`ConfigDataInstall`), still honored.
        public var installConfigData: Bool?
        /// "Install application updates from the App Store" (`AutoUpdate` in `com.apple.commerce`).
        public var installAppUpdates: Bool?

        public init(check: Bool? = nil, download: Bool? = nil, installMacOS: Bool? = nil, installSecurity: Bool? = nil,
                    installConfigData: Bool? = nil, installAppUpdates: Bool? = nil) {
            self.check = check
            self.download = download
            self.installMacOS = installMacOS
            self.installSecurity = installSecurity
            self.installConfigData = installConfigData
            self.installAppUpdates = installAppUpdates
        }

        /// Security data files are installed unless either key turns them off.
        public var installsSecurityResponses: Bool {
            installSecurity != false && installConfigData != false
        }
    }

    /// Reads the update settings from `com.apple.SoftwareUpdate` and `com.apple.commerce`
    /// dictionaries. A managed (profile) dictionary wins over the local one, as in macOS.
    public static func updateSettings(softwareUpdate: [String: Any]?, commerce: [String: Any]?,
                                      managedSoftwareUpdate: [String: Any]? = nil,
                                      managedCommerce: [String: Any]? = nil) -> UpdateSettings {
        func value(_ key: String, _ managed: [String: Any]?, _ local: [String: Any]?) -> Bool? {
            bool(managed?[key]) ?? bool(local?[key])
        }
        return UpdateSettings(
            check: value("AutomaticCheckEnabled", managedSoftwareUpdate, softwareUpdate),
            download: value("AutomaticDownload", managedSoftwareUpdate, softwareUpdate),
            installMacOS: value("AutomaticallyInstallMacOSUpdates", managedSoftwareUpdate, softwareUpdate),
            installSecurity: value("CriticalUpdateInstall", managedSoftwareUpdate, softwareUpdate),
            installConfigData: value("ConfigDataInstall", managedSoftwareUpdate, softwareUpdate),
            installAppUpdates: value("AutoUpdate", managedCommerce, commerce)
        )
    }

    /// An update Software Update found and has not installed yet.
    public struct PendingUpdate: Equatable, Sendable {
        public var name: String
        public var version: String?
        /// A macOS update (an `MSU_UPDATE_…` product), as opposed to tools such as the Command
        /// Line Tools.
        public var isMacOS: Bool
        /// When Software Update first offered it.
        public var offeredAt: Date?

        public init(name: String, version: String? = nil, isMacOS: Bool, offeredAt: Date? = nil) {
            self.name = name
            self.version = version
            self.isMacOS = isMacOS
            self.offeredAt = offeredAt
        }
    }

    /// What Software Update last found, from `com.apple.SoftwareUpdate`: the updates waiting
    /// (`RecommendedUpdates`) and when it last checked (`LastSuccessfulDate`). The list is kept by
    /// macOS's own background checks, so reading it never contacts Apple. `nil` when the
    /// dictionary has neither key.
    public struct UpdateStatus: Equatable, Sendable {
        public var pending: [PendingUpdate]
        public var lastCheck: Date?

        public init(pending: [PendingUpdate], lastCheck: Date?) {
            self.pending = pending
            self.lastCheck = lastCheck
        }
    }

    public static func updateStatus(_ softwareUpdate: [String: Any]?) -> UpdateStatus? {
        guard let softwareUpdate else { return nil }
        let entries = softwareUpdate["RecommendedUpdates"] as? [[String: Any]]
        let lastCheck = softwareUpdate["LastSuccessfulDate"] as? Date
        guard entries != nil || lastCheck != nil else { return nil }
        let offered = softwareUpdate["FirstOfferDateDictionary"] as? [String: Any] ?? [:]
        let pending: [PendingUpdate] = (entries ?? []).compactMap { entry in
            let identifier = (entry["Identifier"] as? String) ?? (entry["Product Key"] as? String) ?? ""
            let rawName = (entry["Display Name"] as? String) ?? identifier
            // Display names use a no-break space ("macOS\u{a0}27.0.1").
            let name = rawName.replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let isMacOS = bool(entry["MobileSoftwareUpdate"]) == true || identifier.hasPrefix("MSU_UPDATE_")
                || name.hasPrefix("macOS ")
            return PendingUpdate(name: name, version: entry["Display Version"] as? String, isMacOS: isMacOS,
                                 offeredAt: offered[identifier] as? Date)
        }
        return UpdateStatus(pending: pending, lastCheck: lastCheck)
    }

    /// The XProtect version from its bundle's Info.plist (`CFBundleShortVersionString`, a plain
    /// number such as "5287").
    public static func xprotectVersion(_ infoPlist: [String: Any]?) -> String? {
        let version = (infoPlist?["CFBundleShortVersionString"] as? String) ?? (infoPlist?["CFBundleVersion"] as? String)
        guard let version, !version.isEmpty else { return nil }
        return version
    }

    /// Orders XProtect versions numerically ("5287" > "999").
    public static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedDescending
    }
}
