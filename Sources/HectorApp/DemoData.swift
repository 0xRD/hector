#if DEBUG
import CryptoKit
import Foundation
import HectorCore

/// Development aid, debug builds only: `HECTOR_DEMO=1` fills the app with fixed sample data, for
/// screenshots that show nothing of the Mac they were taken on.
///
/// Addresses come from the documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24,
/// 2001:db8::/32), host names from the reserved `example` domains, networks from the
/// documentation AS numbers (64496 to 64511), and third-party apps and paths are made up. Apple's
/// own apps and tools keep their real paths, which are the same on every Mac. In demo mode
/// nothing is read from the system, nothing is saved, and the helper is never contacted.
///
///     HECTOR_DEMO=1 HECTOR_SNAPSHOT=/tmp/shot.png swift run HectorApp
@MainActor
enum DemoData {
    static let isEnabled = ProcessInfo.processInfo.environment["HECTOR_DEMO"] != nil

    /// Where the map's lines start: the app's own default, not the Mac's region.
    static let originCountry = "US"

    /// The moment the sample data pretends to have been collected.
    static let now = Date()

    private static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    // MARK: - Connections

    private struct Sample {
        var address: String
        var port: UInt16
        var transport: TransportProtocol = .tcp
        var host: String?
        var country: String
        var network: (UInt32, String)
        /// Live connections now; 0 for a recent destination.
        var live: Int
        /// Seconds since the last activity, for recent destinations.
        var idle: TimeInterval = 0
    }

    private struct SampleApp {
        var id: String
        var name: String
        var bundlePath: String?
        var executablePath: String
        var kind: AppKind
        var processNames: [String]
        var pids: [Int32]
        var destinations: [Sample]
    }

    private static let cdn: (UInt32, String) = (64496, "Example CDN")
    private static let cloud: (UInt32, String) = (64497, "Example Cloud Services")
    private static let media: (UInt32, String) = (64498, "Example Media Network")
    private static let mail: (UInt32, String) = (64499, "Example Mail Hosting")
    private static let transit: (UInt32, String) = (64500, "Example Transit")
    private static let ads: (UInt32, String) = (64501, "Example Ad Exchange")

    private static let sampleApps: [SampleApp] = [
        SampleApp(
            id: "com.apple.Safari", name: "Safari", bundlePath: "/Applications/Safari.app",
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", kind: .app,
            processNames: ["Safari", "com.apple.WebKit.Networking"], pids: [812, 845],
            destinations: [
                Sample(address: "198.51.100.10", port: 443, host: "www.example.com", country: "US", network: cdn, live: 3),
                Sample(address: "198.51.100.24", port: 443, host: "static.example.net", country: "IE", network: cloud, live: 2),
                Sample(address: "2001:db8:10::5", port: 443, host: "video.example.org", country: "NL", network: media, live: 1),
                Sample(address: "192.0.2.80", port: 443, transport: .udp, host: "fonts.example.com", country: "GB", network: cdn, live: 1),
                Sample(address: "203.0.113.50", port: 443, host: "ads.example.net", country: "DE", network: ads, live: 0, idle: 140),
            ]
        ),
        SampleApp(
            id: "com.apple.mail", name: "Mail", bundlePath: "/System/Applications/Mail.app",
            executablePath: "/System/Applications/Mail.app/Contents/MacOS/Mail", kind: .app,
            processNames: ["Mail"], pids: [903],
            destinations: [
                Sample(address: "198.51.100.40", port: 993, host: "imap.example.org", country: "DE", network: mail, live: 2),
                Sample(address: "198.51.100.41", port: 587, host: "smtp.example.org", country: "DE", network: mail, live: 0, idle: 600),
            ]
        ),
        SampleApp(
            id: "com.apple.Music", name: "Music", bundlePath: "/System/Applications/Music.app",
            executablePath: "/System/Applications/Music.app/Contents/MacOS/Music", kind: .app,
            processNames: ["Music"], pids: [1022],
            destinations: [
                Sample(address: "192.0.2.120", port: 443, host: "audio.example.net", country: "SE", network: media, live: 1),
                Sample(address: "2001:db8:20::9", port: 443, host: "art.example.net", country: "JP", network: cdn, live: 0, idle: 420),
            ]
        ),
        SampleApp(
            id: "com.apple.Maps", name: "Maps", bundlePath: "/System/Applications/Maps.app",
            executablePath: "/System/Applications/Maps.app/Contents/MacOS/Maps", kind: .app,
            processNames: ["Maps"], pids: [1107],
            destinations: [
                Sample(address: "192.0.2.150", port: 443, host: "tiles.example.com", country: "SG", network: cloud, live: 1),
            ]
        ),
        SampleApp(
            id: "com.apple.weather", name: "Weather", bundlePath: "/System/Applications/Weather.app",
            executablePath: "/System/Applications/Weather.app/Contents/MacOS/Weather", kind: .app,
            processNames: ["Weather"], pids: [1180],
            destinations: [
                Sample(address: "192.0.2.170", port: 443, host: "forecast.example.org", country: "ZA", network: cloud, live: 1),
                Sample(address: "192.0.2.66", port: 443, host: "tracker.example.com", country: "NL", network: ads, live: 0, idle: 95),
            ]
        ),
        SampleApp(
            id: "com.apple.podcasts", name: "Podcasts", bundlePath: "/System/Applications/Podcasts.app",
            executablePath: "/System/Applications/Podcasts.app/Contents/MacOS/Podcasts", kind: .app,
            processNames: ["Podcasts"], pids: [1214],
            destinations: [
                Sample(address: "203.0.113.90", port: 443, host: "feeds.example.com", country: "CA", network: transit, live: 0, idle: 300),
                Sample(address: "2001:db8:30::7", port: 443, host: "media.example.com", country: "BR", network: media, live: 1),
            ]
        ),
        SampleApp(
            id: "/usr/libexec/apsd", name: "apsd", bundlePath: nil, executablePath: "/usr/libexec/apsd", kind: .system,
            processNames: ["apsd"], pids: [402],
            destinations: [
                Sample(address: "198.51.100.130", port: 5223, host: "push.example.com", country: "US", network: cloud, live: 1),
            ]
        ),
        SampleApp(
            id: "/usr/libexec/nsurlsessiond", name: "nsurlsessiond", bundlePath: nil,
            executablePath: "/usr/libexec/nsurlsessiond", kind: .system,
            processNames: ["nsurlsessiond"], pids: [518],
            destinations: [
                Sample(address: "203.0.113.140", port: 443, host: "downloads.example.net", country: "AU", network: cdn, live: 2),
                Sample(address: "198.51.100.200", port: 443, host: "updates.example.com", country: "IN", network: transit, live: 0, idle: 900),
            ]
        ),
        SampleApp(
            id: "/usr/bin/curl", name: "curl", bundlePath: nil, executablePath: "/usr/bin/curl", kind: .system,
            processNames: ["curl"], pids: [4321],
            destinations: [
                Sample(address: "203.0.113.7", port: 443, host: "api.example.net", country: "FI", network: cloud, live: 1),
            ]
        ),
    ]

    /// Every sample app with its destinations, the way `ConnectionMonitor` would have collected them.
    static func connections() -> [AppGroup] {
        var generator = Wobble(seed: 7)
        let length = ConnectionMonitor.historyLength
        return sampleApps.map { sample in
            var destinations: [DestinationKey: Destination] = [:]
            for item in sample.destinations {
                guard let address = IPAddress(item.address) else { continue }
                let key = DestinationKey(address: address, port: item.port, transport: item.transport)
                let activeUntil = item.live > 0 ? length : max(0, length - Int(item.idle))
                let activity: [Int] = (0..<length).map { index in
                    guard index < activeUntil else { return 0 }
                    return max(0, item.live + generator.next(in: -1...1)) + (generator.next(in: 0...9) == 0 ? 2 : 0)
                }
                destinations[key] = Destination(
                    key: key, country: item.country, network: NetworkOwner(number: item.network.0, name: item.network.1),
                    hostname: item.host, liveConnections: item.live,
                    tcpStates: item.transport == .tcp ? Array(repeating: "ESTABLISHED", count: item.live) : [],
                    firstSeen: ago(1_800 + Double(generator.next(in: 0...1_200))),
                    lastSeen: ago(item.idle), activity: activity
                )
            }
            let activity: [Int] = (0..<length).map { index in
                destinations.values.reduce(0) { $0 + ($1.activity.indices.contains(index) ? $1.activity[index] : 0) }
            }
            return AppGroup(
                id: sample.id, name: sample.name, bundleIdentifier: sample.bundlePath == nil ? nil : sample.id,
                bundlePath: sample.bundlePath, executablePath: sample.executablePath, kind: sample.kind,
                processNames: Set(sample.processNames), pids: Set(sample.pids), destinations: destinations, activity: activity
            )
        }
    }

    /// A small deterministic generator, so every run draws the same sparklines.
    private struct Wobble {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(in range: ClosedRange<Int>) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let span = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int((state >> 33) % span)
        }
    }

    // MARK: - Blocking

    /// What the sample helper enforces.
    static let appliedBlocklist = Blocklist(
        rules: [
            Rule(target: RuleTarget("203.0.113.50")!, note: "Ads seen in Safari", source: .connections, createdAt: ago(86_400 * 3)),
            Rule(target: RuleTarget("192.0.2.66")!, note: "Tracker in Weather", source: .connections, createdAt: ago(86_400)),
            Rule(target: RuleTarget("*.ads.example.net")!, note: "Ad network", createdAt: ago(86_400 * 9)),
            Rule(target: RuleTarget("telemetry.example.com")!, createdAt: ago(86_400 * 12)),
            Rule(target: RuleTarget("198.51.100.128/25")!, isEnabled: false, note: "Testing", createdAt: ago(86_400 * 20)),
        ],
        blockedCountries: ["KP"],
        hostsLists: ["stevenblack-unified", "easyprivacy"]
    )

    /// The draft: the applied list plus one rule not applied yet, so the pending bar shows.
    static var draftBlocklist: Blocklist {
        var draft = appliedBlocklist
        draft.rules.insert(Rule(target: RuleTarget("metrics.example.org")!, note: "Analytics", createdAt: ago(60)), at: 0)
        return draft
    }

    static var helperStatus: HelperStatus {
        HelperStatus(
            version: HectorVersion.current, pfEnabled: true, anchorLoaded: true, appliedAt: ago(3_600),
            blocklist: appliedBlocklist, blockTableCount: 2, geoTableCount: 3, hostsDomainCount: 2, warnings: [],
            listDomainCount: 108_412,
            hostsLists: [
                HostsListState(id: "stevenblack-unified", domainCount: 79_874, updatedAt: ago(86_400 * 2),
                               checkedAt: ago(1_800), attemptedAt: ago(1_800)),
                HostsListState(id: "easyprivacy", domainCount: 28_538, updatedAt: ago(86_400 * 2),
                               checkedAt: ago(1_800), attemptedAt: ago(1_800)),
            ]
        )
    }

    // MARK: - Code signatures and VirusTotal

    private static func signature(_ path: String, _ trust: TrustLevel, team: String? = nil, signer: String? = nil,
                                  identifier: String? = nil) -> CodeSignatureInfo {
        // CodeSignatureInfo has no public memberwise initializer: build it the way the helper's
        // JSON would carry it.
        var json: [String: Any] = [
            "path": path,
            "trustLevel": trust.rawValue,
            "isSigned": trust != .unsigned,
            "isValid": trust != .invalid && trust != .unsigned,
            "isAdHoc": trust == .adHoc,
            "isApplePlatform": trust == .apple,
            "isAppStore": trust == .appStore,
            "isDeveloperID": trust == .developerID || trust == .developerIDNotarized,
            "isNotarized": trust == .developerIDNotarized,
            "hasHardenedRuntime": trust == .apple || trust == .developerIDNotarized,
            "mainExecutable": path,
        ]
        if trust == .apple { json["signerName"] = "Software Signing" }
        if let team { json["teamIdentifier"] = team }
        if let signer { json["signerName"] = signer }
        if let identifier { json["signingIdentifier"] = identifier }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder.hector.decode(CodeSignatureInfo.self, from: data)
    }

    private static func lookup(_ seed: Int, malicious: Int = 0, suspicious: Int = 0, known: Bool = true) -> VirusTotalLookup {
        // A made-up fingerprint that looks like one: the SHA-256 of a sample name.
        let sha = SHA256.hash(data: Data("hector-demo-\(seed)".utf8)).map { String(format: "%02x", $0) }.joined()
        let report = known
            ? VirusTotalReport(sha256: sha, stats: VirusTotalStats(malicious: malicious, suspicious: suspicious,
                                                                   undetected: 72 - malicious - suspicious - 8, harmless: 8),
                               lastAnalysisDate: ago(86_400 * Double(seed % 9 + 1)))
            : nil
        return VirusTotalLookup(sha256: sha, report: report, fetchedAt: ago(1_200), fromCache: seed % 2 == 0)
    }

    private static let exampleTeam = "A1B2C3D4E5"
    private static let otherTeam = "F6G7H8J9K0"

    /// Signatures of every sample path, keyed by path.
    static var signatures: [String: CodeSignatureInfo] {
        var result: [String: CodeSignatureInfo] = [:]
        for item in persistenceItems {
            guard let path = SecurityController.codePath(of: item) else { continue }
            result[path] = persistenceSignature(path)
        }
        for process in processList {
            guard let path = process.executablePath else { continue }
            result[path] = result[path] ?? processSignature(path)
        }
        return result
    }

    private static func persistenceSignature(_ path: String) -> CodeSignatureInfo {
        switch path {
        case "/Applications/Example Sync.app/Contents/Library/LoginItems/Example Sync Helper.app/Contents/MacOS/Example Sync Helper",
             "/Applications/Example Sync.app":
            signature(path, .developerIDNotarized, team: exampleTeam, signer: "Developer ID Application: Example Sync Ltd (\(exampleTeam))")
        case "/Library/PrivilegedHelperTools/com.example.vpn.helper", "/Applications/Example VPN.app":
            signature(path, .developerIDNotarized, team: otherTeam, signer: "Developer ID Application: Example VPN Inc. (\(otherTeam))")
        case "/Applications/Example Notes.app":
            signature(path, .appStore, team: exampleTeam, signer: "Apple Mac OS Application Signing")
        case "/usr/local/bin/backup-tool":
            signature(path, .adHoc, identifier: "backup-tool")
        case "/Users/demo/.local/bin/update-check":
            signature(path, .unsigned)
        default:
            signature(path, .apple, identifier: (path as NSString).lastPathComponent)
        }
    }

    private static func processSignature(_ path: String) -> CodeSignatureInfo {
        if path.hasPrefix("/Users/demo/Downloads/") { return signature(path, .unsigned) }
        if path.hasPrefix("/Applications/Example") {
            return signature(path, .developerIDNotarized, team: exampleTeam, signer: "Developer ID Application: Example Sync Ltd (\(exampleTeam))")
        }
        return signature(path, .apple, identifier: (path as NSString).lastPathComponent)
    }

    /// VirusTotal results for the third-party paths, as if "Check all" had run.
    static var virusTotal: [String: VirusTotalLookup] {
        [
            "/Applications/Example Sync.app/Contents/Library/LoginItems/Example Sync Helper.app/Contents/MacOS/Example Sync Helper": lookup(11),
            "/Library/PrivilegedHelperTools/com.example.vpn.helper": lookup(12),
            "/Applications/Example Notes.app": lookup(13),
            "/Applications/Example VPN.app": lookup(14),
            "/usr/local/bin/backup-tool": lookup(15, known: false),
            "/Users/demo/.local/bin/update-check": lookup(16, suspicious: 2),
            "/Applications/Example Sync.app/Contents/MacOS/Example Sync": lookup(17),
            "/Users/demo/Downloads/Installer Helper": lookup(18, known: false),
        ]
    }

    // MARK: - Persistence

    static let persistenceItems: [PersistenceItem] = [
        PersistenceItem(
            category: .launchAgent, scope: .user, label: "com.example.sync.helper",
            configurationPath: "/Users/demo/Library/LaunchAgents/com.example.sync.helper.plist",
            executablePath: "/Applications/Example Sync.app/Contents/Library/LoginItems/Example Sync Helper.app/Contents/MacOS/Example Sync Helper",
            teamIdentifier: exampleTeam, runAtLoad: true, keepAlive: true,
            owningBundleIdentifier: "com.example.sync", owningBundlePath: "/Applications/Example Sync.app",
            modifiedAt: ago(86_400 * 21)
        ),
        PersistenceItem(
            category: .launchAgent, scope: .user, label: "com.example.update-check",
            configurationPath: "/Users/demo/Library/LaunchAgents/com.example.update-check.plist",
            executablePath: "/Users/demo/.local/bin/update-check",
            arguments: ["/Users/demo/.local/bin/update-check", "--quiet"], runAtLoad: true,
            modifiedAt: ago(86_400 * 2), details: ["startInterval": "3600s"],
            notes: ["no team identifier (unsigned or ad-hoc signed)"]
        ),
        PersistenceItem(
            category: .launchAgent, scope: .apple, label: "com.apple.Safari.History",
            configurationPath: "/System/Library/LaunchAgents/com.apple.Safari.History.plist",
            executablePath: "/System/Library/PrivateFrameworks/SafariShared.framework/Versions/A/XPCServices/com.apple.Safari.History.xpc/Contents/MacOS/com.apple.Safari.History",
            runAtLoad: false
        ),
        PersistenceItem(
            category: .launchDaemon, scope: .system, label: "com.example.vpn.helper",
            configurationPath: "/Library/LaunchDaemons/com.example.vpn.helper.plist",
            executablePath: "/Library/PrivilegedHelperTools/com.example.vpn.helper",
            teamIdentifier: otherTeam, runAtLoad: true, keepAlive: true,
            owningBundleIdentifier: "com.example.vpn", modifiedAt: ago(86_400 * 64)
        ),
        PersistenceItem(
            category: .launchDaemon, scope: .system, label: "org.example.backup",
            configurationPath: "/Library/LaunchDaemons/org.example.backup.plist",
            executablePath: "/usr/local/bin/backup-tool",
            arguments: ["/usr/local/bin/backup-tool", "--nightly"], runAtLoad: false,
            modifiedAt: ago(86_400 * 120), details: ["calendar": "yes"],
            notes: ["no team identifier (unsigned or ad-hoc signed)"]
        ),
        PersistenceItem(
            category: .launchDaemon, scope: .apple, label: "com.apple.softwareupdated",
            configurationPath: "/System/Library/LaunchDaemons/com.apple.softwareupdated.plist",
            executablePath: "/System/Library/PrivateFrameworks/SoftwareUpdateCore.framework/Versions/A/Resources/softwareupdated",
            runAtLoad: true
        ),
        PersistenceItem(
            category: .loginItem, scope: .user, label: "Example Notes",
            executablePath: "/Applications/Example Notes.app", teamIdentifier: exampleTeam,
            owningBundleIdentifier: "com.example.notes", owningBundlePath: "/Applications/Example Notes.app",
            details: ["type": "app", "developer": "Example Notes Ltd"]
        ),
        PersistenceItem(
            category: .systemExtension, scope: .system, label: "com.example.vpn.tunnel",
            executablePath: "/Applications/Example VPN.app", teamIdentifier: otherTeam,
            owningBundleIdentifier: "com.example.vpn", owningBundlePath: "/Applications/Example VPN.app",
            details: ["state": "activated enabled"]
        ),
        PersistenceItem(
            category: .browserExtension, scope: .user, label: "Example Reader",
            configurationPath: "/Users/demo/Library/Application Support/Firefox/Profiles/demo.default/extensions.json",
            details: ["browser": "Firefox", "profile": "demo.default", "extensionID": "reader@example.org", "permissions": "3"]
        ),
    ]

    static var persistenceReport: PersistenceReport {
        PersistenceReport(scannedAt: ago(240), duration: 1.4, ranAsRoot: false, items: persistenceItems, sources: [])
    }

    // MARK: - Processes

    private static let user = "demo"
    private static let userID: UInt32 = 501

    private static func socket(_ address: String, _ port: UInt16, _ transport: TransportProtocol = .tcp) -> SocketInfo {
        SocketInfo(transport: transport, localAddress: nil, localPort: 0, remoteAddress: IPAddress(address),
                   remotePort: port, tcpState: transport == .tcp ? "ESTABLISHED" : nil)
    }

    static let processList: [RunningProcess] = [
        RunningProcess(pid: 1, parentPID: 0, userID: 0, userName: "root", name: "launchd",
                       executablePath: "/sbin/launchd", arguments: ["/sbin/launchd"], startedAt: ago(86_400 * 4), connections: []),
        RunningProcess(pid: 402, parentPID: 1, userID: 0, userName: "root", name: "apsd",
                       executablePath: "/usr/libexec/apsd", arguments: ["/usr/libexec/apsd"], startedAt: ago(86_400 * 4),
                       connections: [socket("198.51.100.130", 5223)]),
        RunningProcess(pid: 518, parentPID: 1, userID: userID, userName: user, name: "nsurlsessiond",
                       executablePath: "/usr/libexec/nsurlsessiond", arguments: ["/usr/libexec/nsurlsessiond"], startedAt: ago(86_400 * 4),
                       connections: [socket("203.0.113.140", 443), socket("203.0.113.140", 443)]),
        RunningProcess(pid: 640, parentPID: 1, userID: 0, userName: "root", name: "mDNSResponder",
                       executablePath: "/usr/sbin/mDNSResponder", arguments: ["/usr/sbin/mDNSResponder"], startedAt: ago(86_400 * 4),
                       connections: []),
        RunningProcess(pid: 152, parentPID: 1, userID: 0, userName: "root", name: "logd",
                       executablePath: "/usr/libexec/logd", arguments: ["/usr/libexec/logd"], startedAt: ago(86_400 * 4), connections: []),
        RunningProcess(pid: 160, parentPID: 1, userID: 0, userName: "root", name: "configd",
                       executablePath: "/usr/libexec/configd", arguments: ["/usr/libexec/configd"], startedAt: ago(86_400 * 4), connections: []),
        RunningProcess(pid: 171, parentPID: 1, userID: 88, userName: "_windowserver", name: "WindowServer",
                       executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
                       arguments: ["/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer", "-daemon"],
                       startedAt: ago(86_400 * 4), connections: []),
        RunningProcess(pid: 188, parentPID: 1, userID: 0, userName: "root", name: "securityd",
                       executablePath: "/usr/sbin/securityd", arguments: ["/usr/sbin/securityd", "-i"], startedAt: ago(86_400 * 4), connections: []),
        RunningProcess(pid: 377, parentPID: 1, userID: userID, userName: user, name: "loginwindow",
                       executablePath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                       arguments: ["/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow", "console"],
                       startedAt: ago(86_400 * 4), appBundlePath: "/System/Library/CoreServices/loginwindow.app",
                       appName: "loginwindow", connections: []),
        RunningProcess(pid: 690, parentPID: 1, userID: userID, userName: user, name: "Dock",
                       executablePath: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                       arguments: ["/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"], startedAt: ago(86_400 * 4),
                       appBundlePath: "/System/Library/CoreServices/Dock.app", appName: "Dock", connections: []),
        RunningProcess(pid: 694, parentPID: 1, userID: userID, userName: user, name: "SystemUIServer",
                       executablePath: "/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer",
                       arguments: ["/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer"],
                       startedAt: ago(86_400 * 4), appBundlePath: "/System/Library/CoreServices/SystemUIServer.app",
                       appName: "SystemUIServer", connections: []),
        RunningProcess(pid: 701, parentPID: 1, userID: userID, userName: user, name: "Finder",
                       executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                       arguments: ["/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"], startedAt: ago(86_400 * 4),
                       appBundlePath: "/System/Library/CoreServices/Finder.app", appName: "Finder", connections: []),
        RunningProcess(pid: 812, parentPID: 1, userID: userID, userName: user, name: "Safari",
                       executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                       arguments: ["/Applications/Safari.app/Contents/MacOS/Safari"], startedAt: ago(7_200),
                       appBundlePath: "/Applications/Safari.app", appName: "Safari", connections: []),
        RunningProcess(pid: 845, parentPID: 1, userID: userID, userName: user, name: "com.apple.WebKit.Networking",
                       executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
                       startedAt: ago(7_100),
                       connections: [socket("198.51.100.10", 443), socket("198.51.100.24", 443), socket("192.0.2.80", 443, .udp)]),
        RunningProcess(pid: 903, parentPID: 1, userID: userID, userName: user, name: "Mail",
                       executablePath: "/System/Applications/Mail.app/Contents/MacOS/Mail",
                       arguments: ["/System/Applications/Mail.app/Contents/MacOS/Mail"], startedAt: ago(14_400),
                       appBundlePath: "/System/Applications/Mail.app", appName: "Mail",
                       connections: [socket("198.51.100.40", 993), socket("198.51.100.40", 993)]),
        RunningProcess(pid: 1022, parentPID: 1, userID: userID, userName: user, name: "Music",
                       executablePath: "/System/Applications/Music.app/Contents/MacOS/Music",
                       arguments: ["/System/Applications/Music.app/Contents/MacOS/Music"], startedAt: ago(3_600),
                       appBundlePath: "/System/Applications/Music.app", appName: "Music",
                       connections: [socket("192.0.2.120", 443)]),
        RunningProcess(pid: 1290, parentPID: 1, userID: userID, userName: user, name: "Example Sync",
                       executablePath: "/Applications/Example Sync.app/Contents/MacOS/Example Sync",
                       arguments: ["/Applications/Example Sync.app/Contents/MacOS/Example Sync"], startedAt: ago(86_400 * 4),
                       appBundlePath: "/Applications/Example Sync.app", appName: "Example Sync", connections: []),
        RunningProcess(pid: 1388, parentPID: 1, userID: userID, userName: user, name: "Terminal",
                       executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                       arguments: ["/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"], startedAt: ago(5_400),
                       appBundlePath: "/System/Applications/Utilities/Terminal.app", appName: "Terminal", connections: []),
        RunningProcess(pid: 1391, parentPID: 1388, userID: userID, userName: user, name: "zsh",
                       executablePath: "/bin/zsh", arguments: ["-zsh"], startedAt: ago(5_400), connections: []),
        RunningProcess(pid: 4321, parentPID: 1391, userID: userID, userName: user, name: "curl",
                       executablePath: "/usr/bin/curl", arguments: ["curl", "-sO", "https://api.example.net/v1/status"],
                       startedAt: ago(4), connections: [socket("203.0.113.7", 443)]),
        RunningProcess(pid: 2050, parentPID: 1, userID: userID, userName: user, name: "Installer Helper",
                       executablePath: "/Users/demo/Downloads/Installer Helper",
                       arguments: ["/Users/demo/Downloads/Installer Helper", "--background"], startedAt: ago(900),
                       connections: []),
    ]

    static var processSnapshot: ProcessSnapshot {
        ProcessSnapshot(takenAt: ago(30), processes: processList.sorted { $0.pid < $1.pid }, ranAsRoot: false)
    }

    static var processFlags: [Int32: Set<ProcessFlag>] {
        Dictionary(uniqueKeysWithValues: processList.map { process in
            (process.pid, process.executablePath?.hasPrefix("/Users/demo/Downloads/") == true ? [.downloads] : [])
        })
    }

    /// Where the flagged download came from.
    static let quarantine: [String: QuarantineInfo?] = Dictionary(uniqueKeysWithValues: processList.map { process in
        let key = process.appBundlePath ?? process.executablePath ?? ""
        let info: QuarantineInfo? = process.pid == 2050
            ? QuarantineInfo(flags: 0x0041, downloadedAt: ago(1_000), agent: "Safari",
                             dataURL: "https://downloads.example.com/installer-helper.zip",
                             originURL: "https://www.example.com/download")
            : nil
        return (key, info)
    })

    static let selectedPersistenceItem = persistenceItems[1].id
    static let selectedProcess: Int32 = 2050

    // MARK: - Checkup

    static var checkupReport: CheckupReport {
        typealias ID = SecurityCheckup.CheckID
        let sharingFix = { (title: String) in "System Settings → General → Sharing → turn off \(title), unless you use it." }
        let results: [CheckResult] = [
            CheckResult(id: ID.sip, title: "System Integrity Protection", status: .pass,
                        finding: "On: system files and Apple's processes are protected, even from root.",
                        howToFix: "Start up in macOS Recovery, choose Utilities → Terminal, run `csrutil enable`, then restart."),
            CheckResult(id: ID.gatekeeper, title: "Gatekeeper", status: .pass,
                        finding: "On: downloaded apps must be signed and notarized, or approved by you once.",
                        howToFix: "System Settings → Privacy & Security → Security → Allow applications from “App Store & Known Developers”. "
                            + "If that choice is missing, run `sudo spctl --global-enable` in Terminal.",
                        settingsURL: SettingsPane.privacySecurity),
            CheckResult(id: ID.xprotect, title: "XProtect", status: .pass,
                        finding: "Version 5321. Apple's built-in malware signatures update automatically.",
                        howToFix: "XProtect updates itself while “Install Security Responses and system files” is on: "
                            + "System Settings → General → Software Update → Automatic Updates (ⓘ).",
                        settingsURL: SettingsPane.softwareUpdate),
            CheckResult(id: ID.fileVault, title: "FileVault", status: .pass,
                        finding: "On: the disk is encrypted and unreadable without your password.",
                        howToFix: "System Settings → Privacy & Security → FileVault → Turn On…, and keep the recovery key somewhere safe.",
                        settingsURL: SettingsPane.privacySecurity),
            CheckResult(id: ID.firewall, title: "Firewall", status: .warning,
                        finding: "Off: any app that listens on the network can be reached from it.",
                        howToFix: "System Settings → Network → Firewall → turn it on. Under Options…, “Enable stealth mode” also stops "
                            + "this Mac from answering pings and port scans.",
                        settingsURL: SettingsPane.network),
            CheckResult(id: ID.automaticUpdates, title: "Automatic updates", status: .warning,
                        finding: "Security responses install automatically; off: installing macOS updates.",
                        howToFix: "System Settings → General → Software Update → Automatic Updates (ⓘ): turn every switch on, "
                            + "at least “Install Security Responses and system files”.",
                        settingsURL: SettingsPane.softwareUpdate),
            CheckResult(id: ID.remoteLogin, title: "Remote Login (SSH)", status: .pass, finding: "Off.",
                        howToFix: "System Settings → General → Sharing → turn off Remote Login, unless you reach this Mac with SSH.",
                        settingsURL: SettingsPane.sharing),
            CheckResult(id: ID.screenSharing, title: "Screen Sharing and Remote Management", status: .pass, finding: "Off.",
                        howToFix: "System Settings → General → Sharing → turn off Screen Sharing and Remote Management, unless you use them.",
                        settingsURL: SettingsPane.sharing),
            CheckResult(id: ID.fileSharing, title: "File Sharing", status: .pass, finding: "Off.",
                        howToFix: sharingFix("File Sharing"), settingsURL: SettingsPane.sharing),
            CheckResult(id: ID.remoteAppleEvents, title: "Remote Apple Events", status: .pass, finding: "Off.",
                        howToFix: sharingFix("Remote Apple Events"), settingsURL: SettingsPane.sharing),
            CheckResult(id: ID.automaticLogin, title: "Automatic login", status: .pass,
                        finding: "Off: a password is needed after every start.",
                        howToFix: "System Settings → Users & Groups → “Automatically log in as”: Off. Turning FileVault on also turns it off.",
                        settingsURL: SettingsPane.usersGroups),
            CheckResult(id: ID.guestAccount, title: "Guest account", status: .pass, finding: "Off.",
                        howToFix: "System Settings → Users & Groups → Guest User (ⓘ) → turn off “Allow guests to log in to this computer”.",
                        settingsURL: SettingsPane.usersGroups),
            CheckResult(id: ID.deviceManagement, title: "Device management (MDM)", status: .pass,
                        finding: "Not enrolled: no organization manages this Mac.",
                        howToFix: "Expected on a work or school Mac. Otherwise, see who manages it in System Settings → General → "
                            + "Device Management, and remove any profile you do not recognize.",
                        settingsURL: SettingsPane.deviceManagement),
        ]
        return CheckupReport(checkedAt: ago(120), duration: 0.8, ranAsRoot: false, results: results)
    }
}
#endif
