import Foundation

/// The verdict of one security checkup item, with what was found and how to fix it.
public struct CheckResult: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, CaseIterable, Comparable, Sendable {
        /// The setting is where it should be.
        case pass
        /// Worth a look: a deliberate choice on some Macs (sharing, MDM), or a weaker setting.
        case warning
        /// A protection is off.
        case fail
        /// Could not be read without root, or the tool printed something unexpected.
        case unknown

        /// Most urgent first, for sorting: fail, warning, unknown, pass.
        public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rank < rhs.rank }

        private var rank: Int {
            switch self {
            case .fail: 0
            case .warning: 1
            case .unknown: 2
            case .pass: 3
            }
        }
    }

    /// Stable identifier, such as `filevault`, for scripts and for the app's icons.
    public var id: String
    public var title: String
    public var status: Status
    /// One line: what was found ("FileVault is off.").
    public var finding: String
    /// Short instructions: a System Settings path or a command. Written for the failing case; it
    /// also tells where the setting lives when the check passes.
    public var howToFix: String
    /// An `x-apple.systempreferences:` link to the right pane, when there is one.
    public var settingsURL: URL?

    public init(id: String, title: String, status: Status, finding: String, howToFix: String, settingsURL: URL? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.finding = finding
        self.howToFix = howToFix
        self.settingsURL = settingsURL
    }
}

/// Everything one run of the checkup found.
public struct CheckupReport: Codable, Sendable {
    public var checkedAt: Date
    /// Seconds the run took.
    public var duration: TimeInterval
    public var ranAsRoot: Bool
    /// In a fixed order (see `SecurityCheckup.run()`), not sorted by status.
    public var results: [CheckResult]

    public init(checkedAt: Date, duration: TimeInterval, ranAsRoot: Bool, results: [CheckResult]) {
        self.checkedAt = checkedAt
        self.duration = duration
        self.ranAsRoot = ranAsRoot
        self.results = results
    }

    public var passedCount: Int { count(.pass) }

    public func count(_ status: CheckResult.Status) -> Int { results.filter { $0.status == status }.count }

    /// "8 of 11 checks pass".
    public var summary: String { "\(passedCount) of \(results.count) checks pass" }
}

/// Links that open a System Settings pane (macOS 13 and later identifiers). Only this scheme is
/// ever produced, and the app refuses any other before opening a link.
public enum SettingsPane {
    public static let scheme = "x-apple.systempreferences"

    public static let privacySecurity = url("com.apple.settings.PrivacySecurity.extension")
    public static let network = url("com.apple.Network-Settings.extension")
    public static let softwareUpdate = url("com.apple.Software-Update-Settings.extension")
    public static let sharing = url("com.apple.Sharing-Settings.extension")
    public static let usersGroups = url("com.apple.Users-Groups-Settings.extension")
    public static let deviceManagement = url("com.apple.Profiles-Settings.extension")

    /// True for the links above; anything else must not be opened.
    public static func isSettingsLink(_ url: URL) -> Bool { url.scheme == scheme }

    private static func url(_ pane: String) -> URL? { URL(string: "\(scheme):\(pane)") }
}
