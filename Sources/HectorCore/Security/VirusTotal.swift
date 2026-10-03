import Foundation

// VirusTotal API v3, hash lookups only. Files are never uploaded: this client has no upload API on
// purpose, because sending a user's binary to a third party must stay an explicit, separate choice.

/// Detection counts from the engines' last analysis of a file.
public struct VirusTotalStats: Codable, Hashable, Sendable {
    public var malicious: Int
    public var suspicious: Int
    public var undetected: Int
    public var harmless: Int
    public var timeout: Int
    public var confirmedTimeout: Int
    public var failure: Int
    public var typeUnsupported: Int

    public init(malicious: Int = 0, suspicious: Int = 0, undetected: Int = 0, harmless: Int = 0,
                timeout: Int = 0, confirmedTimeout: Int = 0, failure: Int = 0, typeUnsupported: Int = 0) {
        self.malicious = malicious
        self.suspicious = suspicious
        self.undetected = undetected
        self.harmless = harmless
        self.timeout = timeout
        self.confirmedTimeout = confirmedTimeout
        self.failure = failure
        self.typeUnsupported = typeUnsupported
    }

    /// Engines that reached a verdict, the denominator VirusTotal shows ("3 / 72").
    /// Timeouts, failures and unsupported file types are left out, as on the website.
    public var verdictCount: Int { malicious + suspicious + undetected + harmless }
}

/// What VirusTotal knows about a file.
public struct VirusTotalReport: Codable, Hashable, Sendable {
    public var sha256: String
    public var stats: VirusTotalStats
    public var lastAnalysisDate: Date?
    public var meaningfulName: String?
    /// `popular_threat_classification.suggested_threat_label`, e.g. "trojan.amos/stealer".
    public var threatLabel: String?

    public init(sha256: String, stats: VirusTotalStats, lastAnalysisDate: Date? = nil,
                meaningfulName: String? = nil, threatLabel: String? = nil) {
        self.sha256 = sha256
        self.stats = stats
        self.lastAnalysisDate = lastAnalysisDate
        self.meaningfulName = meaningfulName
        self.threatLabel = threatLabel
    }
}

/// The outcome of a hash lookup. A file VirusTotal has never seen is a result, not an error.
public struct VirusTotalLookup: Codable, Hashable, Sendable {
    public var sha256: String
    /// `nil` when VirusTotal does not know the file (HTTP 404).
    public var report: VirusTotalReport?
    public var fetchedAt: Date
    public var fromCache: Bool
    public var permalink: URL

    public init(sha256: String, report: VirusTotalReport?, fetchedAt: Date, fromCache: Bool = false) {
        self.sha256 = sha256
        self.report = report
        self.fetchedAt = fetchedAt
        self.fromCache = fromCache
        self.permalink = VirusTotalClient.permalink(for: sha256)
    }

    public var isKnown: Bool { report != nil }
}

/// Failures of a lookup. No case carries or prints the API key.
public enum VirusTotalError: Error, Equatable, CustomStringConvertible {
    case invalidHash(String)
    case invalidAPIKey
    /// HTTP 429 from VirusTotal: the per-minute or daily quota of the key is used up.
    case rateLimited
    /// Refused locally before sending: the daily budget of the free tier is spent.
    case dailyQuotaExhausted(limit: Int)
    case insecureURL
    case redirectRejected
    case httpStatus(Int)
    case malformedResponse
    case transport(String)

    public var description: String {
        switch self {
        case .invalidHash(let value): "Not a SHA-256 hash: \(value.prefix(80))"
        case .invalidAPIKey: "VirusTotal rejected the API key, or it is not 64 hexadecimal characters."
        case .rateLimited: "VirusTotal refused the request: the key's quota is used up (HTTP 429). Try again later."
        case .dailyQuotaExhausted(let limit):
            "Already \(limit) VirusTotal lookups today, the free tier limit. Cached results still work; new lookups resume after midnight UTC."
        case .insecureURL: "Refusing to contact VirusTotal over anything but HTTPS."
        case .redirectRejected: "VirusTotal answered with a redirect, which is refused so the API key cannot leak elsewhere."
        case .httpStatus(let code): "Unexpected HTTP status \(code) from VirusTotal."
        case .malformedResponse: "VirusTotal sent a response that could not be understood."
        case .transport(let message): "Could not reach VirusTotal: \(message)"
        }
    }
}

// MARK: - Transport

/// Sends one HTTP request. Injectable so tests never touch the network.
public protocol VirusTotalTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport: an ephemeral `URLSession` (no cookies, no disk cache) with short
/// timeouts that refuses redirects leaving HTTPS or virustotal.com.
public final class URLSessionVirusTotalTransport: VirusTotalTransport {
    private let session: URLSession

    /// `configuration` is copied; tests pass one with stub `protocolClasses`.
    public init(configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 15) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit {
        // A session retains its delegate until invalidated.
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme?.lowercased() == "https" else { throw VirusTotalError.insecureURL }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VirusTotalError.malformedResponse }
        // When the guard refuses a redirect, URLSession hands back the 3xx response itself.
        if (300..<400).contains(http.statusCode) { throw VirusTotalError.redirectRejected }
        return (data, http)
    }
}

/// Follows a redirect only to HTTPS on virustotal.com. URLSession carries custom headers over to
/// the new request, so following one anywhere else would hand the `x-apikey` header to that host.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static func allows(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased() else { return false }
        return host == "virustotal.com" || host.hasSuffix(".virustotal.com")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        Self.allows(request) ? request : nil
    }
}

// MARK: - Rate limiter

/// Keeps lookups within the free tier: at most `perMinute` requests in any 60 seconds (waiting
/// when needed) and `perDay` per UTC day (refusing beyond that).
///
/// With a `stateURL` the counters survive across processes, so running the CLI repeatedly still
/// respects the limits.
public actor VirusTotalRateLimiter {
    public let perMinute: Int
    public let perDay: Int
    private let stateURL: URL?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let onWait: (@Sendable (TimeInterval) -> Void)?
    private var state: State

    struct State: Codable {
        /// Send times, seconds since 1970, of the requests in the current minute window.
        var recent: [Double] = []
        /// Days since 1970 in UTC, which is when VirusTotal resets daily quotas.
        var day: Int = 0
        var dayCount: Int = 0
    }

    /// - Parameters:
    ///   - now, sleep: injectable clock for tests.
    ///   - onWait: told how long the limiter is about to wait, so a UI can say why it is slow.
    public init(perMinute: Int = 4, perDay: Int = 500, stateURL: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                onWait: (@Sendable (TimeInterval) -> Void)? = nil) {
        self.perMinute = max(1, perMinute)
        self.perDay = max(1, perDay)
        self.stateURL = stateURL
        self.now = now
        self.sleep = sleep
        self.onWait = onWait
        self.state = stateURL.flatMap { try? JSONDecoder().decode(State.self, from: Data(contentsOf: $0)) } ?? State()
    }

    /// Waits until a request may be sent, then counts it.
    /// Throws `VirusTotalError.dailyQuotaExhausted` instead of waiting until tomorrow.
    public func acquire() async throws {
        while true {
            let current = now().timeIntervalSince1970
            let today = Int((current / 86_400).rounded(.down))
            if state.day != today {
                state.day = today
                state.dayCount = 0
            }
            guard state.dayCount < perDay else { throw VirusTotalError.dailyQuotaExhausted(limit: perDay) }

            // Entries in the future mean the clock went back; dropping them avoids a long stall.
            state.recent.removeAll { current - $0 >= 60 || $0 > current }
            if state.recent.count < perMinute {
                state.recent.append(current)
                state.dayCount += 1
                save()
                return
            }
            let wait = max(60 - (current - (state.recent.min() ?? current)), 0.05)
            onWait?(wait)
            // Another caller may take the slot while this one sleeps (actor reentrancy): loop and re-check.
            try await sleep(wait)
        }
    }

    /// Lookups still allowed today.
    public var remainingToday: Int {
        let today = Int((now().timeIntervalSince1970 / 86_400).rounded(.down))
        return state.day == today ? max(0, perDay - state.dayCount) : perDay
    }

    private func save() {
        guard let stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: stateURL, options: .atomic)
    }
}

// MARK: - Cache

/// Lookup results on disk, one JSON file per SHA-256, so repeated scans cost no quota.
public struct VirusTotalCache: Sendable {
    public static var defaultDirectory: URL {
        LegacyMigration.userDataDirectory
            .appending(path: "virustotal-cache", directoryHint: .isDirectory)
    }

    public let directory: URL
    /// How long a report stays fresh. Detections change slowly once a file is a few days old.
    public let ttl: TimeInterval
    /// Shorter for files VirusTotal did not know: someone may submit them in the meantime.
    public let unknownTTL: TimeInterval

    public init(directory: URL = defaultDirectory, ttl: TimeInterval = 7 * 86_400, unknownTTL: TimeInterval = 86_400) {
        self.directory = directory
        self.ttl = ttl
        self.unknownTTL = unknownTTL
    }

    /// A fresh cached result, or `nil` when missing, expired, unreadable or the hash is invalid.
    public func lookup(sha256: String, now: Date = Date()) -> VirusTotalLookup? {
        guard let url = fileURL(for: sha256),
              let data = try? Data(contentsOf: url),
              var entry = try? JSONDecoder.hector.decode(VirusTotalLookup.self, from: data),
              entry.sha256 == sha256.lowercased() else { return nil }
        let age = now.timeIntervalSince(entry.fetchedAt)
        // A negative age beyond clock jitter means the entry cannot be trusted to be recent.
        guard age > -300, age < (entry.isKnown ? ttl : unknownTTL) else { return nil }
        entry.fromCache = true
        return entry
    }

    public func store(_ lookup: VirusTotalLookup) throws {
        guard let url = fileURL(for: lookup.sha256) else { throw VirusTotalError.invalidHash(lookup.sha256) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var entry = lookup
        entry.fromCache = false
        try JSONEncoder.hector.encode(entry).write(to: url, options: .atomic)
    }

    /// The cache file for a hash. The hash is validated first so it can never escape `directory`.
    func fileURL(for sha256: String) -> URL? {
        guard FileHash.isValidSHA256(sha256) else { return nil }
        return directory.appending(path: "\(sha256.lowercased()).json", directoryHint: .notDirectory)
    }
}

// MARK: - Client

/// Looks up file hashes on VirusTotal, through the cache and the rate limiter.
public final class VirusTotalClient: Sendable {
    public static let filesEndpoint = URL(string: "https://www.virustotal.com/api/v3/files/")!

    private let apiKey: String
    private let transport: any VirusTotalTransport
    public let cache: VirusTotalCache?
    public let rateLimiter: VirusTotalRateLimiter
    private let now: @Sendable () -> Date

    /// The default rate limiter keeps its counters next to the default cache, shared by every process.
    public static func defaultRateLimiter(onWait: (@Sendable (TimeInterval) -> Void)? = nil) -> VirusTotalRateLimiter {
        VirusTotalRateLimiter(stateURL: VirusTotalCache.defaultDirectory.appending(path: "rate-limit.json"), onWait: onWait)
    }

    /// Throws `VirusTotalError.invalidAPIKey` when `apiKey` is not shaped like a VirusTotal key.
    public init(apiKey: String,
                transport: any VirusTotalTransport = URLSessionVirusTotalTransport(),
                cache: VirusTotalCache? = VirusTotalCache(),
                rateLimiter: VirusTotalRateLimiter = VirusTotalClient.defaultRateLimiter(),
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIKeyStore.isValidVirusTotalKey(key) else { throw VirusTotalError.invalidAPIKey }
        self.apiKey = key
        self.transport = transport
        self.cache = cache
        self.rateLimiter = rateLimiter
        self.now = now
    }

    /// The page a person can open to see the full report.
    public static func permalink(for sha256: String) -> URL {
        // Only valid hashes reach here from this module; the fallback keeps a bad one out of the path.
        let hash = FileHash.isValidSHA256(sha256) ? sha256.lowercased() : ""
        return URL(string: "https://www.virustotal.com/gui/file/\(hash)")!
    }

    /// Hashes the file at `url` and looks it up.
    public func lookup(fileAt url: URL, refresh: Bool = false) async throws -> VirusTotalLookup {
        try await lookup(sha256: try FileHash.sha256(of: url), refresh: refresh)
    }

    /// Looks up a SHA-256, from the cache when fresh unless `refresh` is set.
    public func lookup(sha256: String, refresh: Bool = false) async throws -> VirusTotalLookup {
        let hash = sha256.lowercased()
        guard FileHash.isValidSHA256(hash) else { throw VirusTotalError.invalidHash(sha256) }
        if !refresh, let cached = cache?.lookup(sha256: hash, now: now()) { return cached }

        try await rateLimiter.acquire()
        var request = URLRequest(url: Self.filesEndpoint.appending(path: hash))
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as VirusTotalError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // localizedDescription of a URLError names the failure, never the request headers.
            throw VirusTotalError.transport(error.localizedDescription)
        }

        let lookup: VirusTotalLookup
        switch response.statusCode {
        case 200: lookup = VirusTotalLookup(sha256: hash, report: try Self.parseReport(data, sha256: hash), fetchedAt: now())
        case 404: lookup = VirusTotalLookup(sha256: hash, report: nil, fetchedAt: now())
        case 401, 403: throw VirusTotalError.invalidAPIKey
        case 429: throw VirusTotalError.rateLimited
        default: throw VirusTotalError.httpStatus(response.statusCode)
        }
        // A cache that cannot be written only costs quota later; the answer is still good.
        try? cache?.store(lookup)
        return lookup
    }

    /// Parses the body of `GET /api/v3/files/{sha256}`.
    public static func parseReport(_ data: Data, sha256: String) throws -> VirusTotalReport {
        guard let envelope = try? JSONDecoder().decode(Wire.Envelope.self, from: data) else {
            throw VirusTotalError.malformedResponse
        }
        let attributes = envelope.data.attributes
        let hash = sha256.lowercased()
        // Never attach someone else's verdict to this file.
        if let reported = attributes.sha256 ?? envelope.data.id, reported.lowercased() != hash {
            throw VirusTotalError.malformedResponse
        }
        let raw = attributes.lastAnalysisStats
        return VirusTotalReport(
            sha256: hash,
            stats: VirusTotalStats(
                malicious: raw?.malicious ?? 0, suspicious: raw?.suspicious ?? 0,
                undetected: raw?.undetected ?? 0, harmless: raw?.harmless ?? 0,
                timeout: raw?.timeout ?? 0, confirmedTimeout: raw?.confirmedTimeout ?? 0,
                failure: raw?.failure ?? 0, typeUnsupported: raw?.typeUnsupported ?? 0
            ),
            lastAnalysisDate: attributes.lastAnalysisDate.map { Date(timeIntervalSince1970: $0) },
            meaningfulName: attributes.meaningfulName,
            threatLabel: attributes.popularThreatClassification?.suggestedThreatLabel
        )
    }

    /// The JSON shapes of the v3 API, decoded leniently: every field VirusTotal may omit is optional.
    enum Wire {
        struct Envelope: Decodable { let data: FileObject }

        struct FileObject: Decodable {
            let id: String?
            let attributes: Attributes
        }

        struct Attributes: Decodable {
            let sha256: String?
            let lastAnalysisStats: Stats?
            let lastAnalysisDate: Double?
            let meaningfulName: String?
            let popularThreatClassification: ThreatClassification?

            enum CodingKeys: String, CodingKey {
                case sha256
                case lastAnalysisStats = "last_analysis_stats"
                case lastAnalysisDate = "last_analysis_date"
                case meaningfulName = "meaningful_name"
                case popularThreatClassification = "popular_threat_classification"
            }
        }

        struct Stats: Decodable {
            let malicious, suspicious, undetected, harmless, timeout, failure: Int?
            let confirmedTimeout, typeUnsupported: Int?

            enum CodingKeys: String, CodingKey {
                case malicious, suspicious, undetected, harmless, timeout, failure
                case confirmedTimeout = "confirmed-timeout"
                case typeUnsupported = "type-unsupported"
            }
        }

        struct ThreatClassification: Decodable {
            let suggestedThreatLabel: String?

            enum CodingKeys: String, CodingKey { case suggestedThreatLabel = "suggested_threat_label" }
        }
    }
}

extension VirusTotalClient: CustomReflectable {
    // Keeps the API key out of `dump()` and debugger summaries.
    public var customMirror: Mirror {
        Mirror(self, children: ["cache": cache as Any], displayStyle: .class)
    }
}
