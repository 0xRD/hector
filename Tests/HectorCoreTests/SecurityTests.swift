import Foundation
import Testing
@testable import HectorCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "hector-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct FileHashTests {
    @Test func hashesKnownContent() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let abc = dir.appending(path: "abc")
        try Data("abc".utf8).write(to: abc)
        #expect(try FileHash.sha256(of: abc) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let empty = dir.appending(path: "empty")
        try Data().write(to: empty)
        #expect(try FileHash.sha256(of: empty) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func streamingMatchesOneShotAcrossChunks() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two and a half chunks, with content that differs per position so chunk order matters.
        let data = Data((0..<(FileHash.chunkSize * 5 / 2)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        let file = dir.appending(path: "big")
        try data.write(to: file)
        #expect(try FileHash.sha256(of: file) == FileHash.sha256(data))
    }

    @Test func refusesDirectoriesAndMissingFiles() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: FileHash.HashError.self) { try FileHash.sha256(of: dir) }
        #expect(throws: FileHash.HashError.self) { try FileHash.sha256(of: dir.appending(path: "missing")) }
    }

    @Test func validatesSHA256Strings() {
        #expect(FileHash.isValidSHA256(String(repeating: "a", count: 64)))
        #expect(FileHash.isValidSHA256("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
        for bad in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "g", count: 64),
                    "../" + String(repeating: "a", count: 61), String(repeating: "a", count: 63) + "/",
                    String(repeating: "é", count: 32)] {
            #expect(!FileHash.isValidSHA256(bad), "\(bad)")
        }
    }
}

@Suite struct CodeSignatureTests {
    @Test func recognizesApplePlatformBinaries() throws {
        let info = try CodeSignature.analyze(URL(fileURLWithPath: "/bin/ls"))
        #expect(info.trustLevel == .apple)
        #expect(info.isSigned && info.isValid && info.isApplePlatform)
        #expect(!info.isAdHoc && !info.isDeveloperID)
        #expect(info.signingIdentifier == "com.apple.ls")
    }

    @Test func reportsUnsignedFiles() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "plain.bin")
        try Data([0xCA, 0xFE, 0x00, 0x01, 0x02]).write(to: file)
        let info = try CodeSignature.analyze(file)
        #expect(info.trustLevel == .unsigned)
        #expect(!info.isSigned && info.signingIdentifier == nil)
    }

    @Test func reportsAdHocAndBrokenSignatures() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appending(path: "true-copy")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        try #require(try codesign(["-s", "-", "--force", binary.path]) == 0)

        let adHoc = try CodeSignature.analyze(binary)
        #expect(adHoc.trustLevel == .adHoc)
        #expect(adHoc.isSigned && adHoc.isValid && adHoc.isAdHoc)
        #expect(adHoc.teamIdentifier == nil && !adHoc.isApplePlatform)

        // A non-Mach-O file keeps its signature in extended attributes; appending in place keeps
        // them while changing the content, which must break the signature.
        let script = dir.appending(path: "script.sh")
        try Data("#!/bin/sh\necho hello\n".utf8).write(to: script)
        try #require(try codesign(["-s", "-", "--force", script.path]) == 0)
        #expect(try CodeSignature.analyze(script).trustLevel == .adHoc)
        let handle = try FileHandle(forWritingTo: script)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("echo tampered\n".utf8))
        try handle.close()
        let broken = try CodeSignature.analyze(script)
        #expect(broken.trustLevel == .invalid)
        #expect(broken.isSigned && !broken.isValid && broken.validationError != nil)
    }

    @Test func failsCleanlyOnMissingPaths() {
        #expect(throws: CodeSignature.AnalysisError.self) { try CodeSignature.analyze(URL(fileURLWithPath: "/nonexistent/netbite")) }
    }

    @Test func ranksTrustLevels() {
        var info = CodeSignatureInfo(path: "/x", trustLevel: .unsigned, isSigned: true, isValid: true, isAdHoc: false,
                                     isApplePlatform: false, isAppStore: false, isDeveloperID: true, isNotarized: true,
                                     hasHardenedRuntime: true)
        #expect(CodeSignature.trustLevel(of: info) == .developerIDNotarized)
        info.isNotarized = false
        #expect(CodeSignature.trustLevel(of: info) == .developerID)
        info.isDeveloperID = false
        #expect(CodeSignature.trustLevel(of: info) == .otherCertificate)
        info.isValid = false
        #expect(CodeSignature.trustLevel(of: info) == .invalid)
        #expect(Set(TrustLevel.allCases.map(\.label)).count == TrustLevel.allCases.count)
    }

    private func codesign(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

// MARK: - VirusTotal

/// A clock tests move by hand; sleeping advances it instantly.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recordedSleeps: [TimeInterval] = []

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    var sleeps: [TimeInterval] { lock.withLock { recordedSleeps } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            recordedSleeps.append(seconds)
            current += seconds
        }
    }
}

/// Answers every request with a fixed status and body, and records what was asked.
private final class StubTransport: VirusTotalTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int
    private var body: Data
    private var recorded: [URLRequest] = []

    init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func respond(status: Int, body: Data = Data()) {
        lock.withLock {
            self.status = status
            self.body = body
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            recorded.append(request)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }
}

@Suite struct VirusTotalTests {
    static let key = String(repeating: "0123456789abcdef", count: 4)
    static let hash = "275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f"

    // Trimmed from a real v3 file object (EICAR test file).
    static let fixture = """
    {
      "data": {
        "id": "275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f",
        "type": "file",
        "links": {"self": "https://www.virustotal.com/api/v3/files/275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f"},
        "attributes": {
          "sha256": "275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f",
          "meaningful_name": "eicar.com",
          "last_analysis_date": 1790000000,
          "last_analysis_stats": {
            "malicious": 63, "suspicious": 1, "undetected": 7, "harmless": 0, "timeout": 2,
            "confirmed-timeout": 1, "failure": 1, "type-unsupported": 3
          },
          "popular_threat_classification": {
            "suggested_threat_label": "virus.eicar/test",
            "popular_threat_category": [{"count": 30, "value": "virus"}]
          },
          "last_analysis_results": {"ExampleAV": {"category": "malicious", "result": "EICAR-Test-File"}}
        }
      }
    }
    """

    private func makeClient(_ transport: StubTransport, clock: TestClock, cacheDirectory: URL?,
                            limiter: VirusTotalRateLimiter? = nil) throws -> VirusTotalClient {
        try VirusTotalClient(
            apiKey: Self.key, transport: transport,
            cache: cacheDirectory.map { VirusTotalCache(directory: $0) },
            rateLimiter: limiter ?? VirusTotalRateLimiter(perMinute: 1000, perDay: 1000, now: { clock.now }, sleep: { clock.sleep($0) }),
            now: { clock.now }
        )
    }

    @Test func parsesFileReports() async throws {
        let transport = StubTransport(status: 200, body: Data(Self.fixture.utf8))
        let client = try makeClient(transport, clock: TestClock(), cacheDirectory: nil)
        let lookup = try await client.lookup(sha256: Self.hash.uppercased())

        let report = try #require(lookup.report)
        #expect(report.sha256 == Self.hash)
        #expect(report.stats == VirusTotalStats(malicious: 63, suspicious: 1, undetected: 7, harmless: 0, timeout: 2,
                                                confirmedTimeout: 1, failure: 1, typeUnsupported: 3))
        #expect(report.stats.verdictCount == 71)
        #expect(report.lastAnalysisDate == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(report.meaningfulName == "eicar.com")
        #expect(report.threatLabel == "virus.eicar/test")
        #expect(lookup.permalink.absoluteString == "https://www.virustotal.com/gui/file/\(Self.hash)")
        #expect(!lookup.fromCache)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://www.virustotal.com/api/v3/files/\(Self.hash)")
        #expect(request.value(forHTTPHeaderField: "x-apikey") == Self.key)
        #expect(request.httpBody == nil)
    }

    @Test func toleratesSparseReports() throws {
        let sparse = #"{"data": {"id": "\#(Self.hash)", "attributes": {}}}"#
        let report = try VirusTotalClient.parseReport(Data(sparse.utf8), sha256: Self.hash)
        #expect(report.stats == VirusTotalStats())
        #expect(report.threatLabel == nil && report.lastAnalysisDate == nil)
    }

    @Test func rejectsMalformedOrMismatchedReports() {
        let other = String(repeating: "b", count: 64)
        #expect(throws: VirusTotalError.malformedResponse) {
            try VirusTotalClient.parseReport(Data(Self.fixture.utf8), sha256: other)
        }
        #expect(throws: VirusTotalError.malformedResponse) {
            try VirusTotalClient.parseReport(Data("<html>".utf8), sha256: Self.hash)
        }
    }

    @Test func treatsNotFoundAsUnknownFile() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = StubTransport(status: 404, body: Data(#"{"error": {"code": "NotFoundError"}}"#.utf8))
        let client = try makeClient(transport, clock: TestClock(), cacheDirectory: dir)

        let lookup = try await client.lookup(sha256: Self.hash)
        #expect(!lookup.isKnown && lookup.report == nil)
        #expect(lookup.permalink.absoluteString.hasSuffix(Self.hash))
    }

    @Test func mapsHTTPErrors() async throws {
        let cases: [(Int, VirusTotalError)] = [
            (401, .invalidAPIKey), (403, .invalidAPIKey), (429, .rateLimited), (500, .httpStatus(500)),
        ]
        for (status, expected) in cases {
            let client = try makeClient(StubTransport(status: status), clock: TestClock(), cacheDirectory: nil)
            await #expect(throws: expected) { try await client.lookup(sha256: Self.hash) }
        }
    }

    @Test func cachesUntilTheTTLExpires() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let transport = StubTransport(status: 200, body: Data(Self.fixture.utf8))
        let client = try makeClient(transport, clock: clock, cacheDirectory: dir)

        _ = try await client.lookup(sha256: Self.hash)
        clock.advance(6 * 86_400)
        let cached = try await client.lookup(sha256: Self.hash)
        #expect(cached.fromCache && cached.report?.stats.malicious == 63)
        #expect(transport.requests.count == 1)

        _ = try await client.lookup(sha256: Self.hash, refresh: true)
        #expect(transport.requests.count == 2)

        clock.advance(7 * 86_400 + 1)
        let fresh = try await client.lookup(sha256: Self.hash)
        #expect(!fresh.fromCache)
        #expect(transport.requests.count == 3)
    }

    @Test func expiresUnknownResultsSooner() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let transport = StubTransport(status: 404)
        let client = try makeClient(transport, clock: clock, cacheDirectory: dir)

        _ = try await client.lookup(sha256: Self.hash)
        clock.advance(23 * 3_600)
        #expect(try await client.lookup(sha256: Self.hash).fromCache)
        clock.advance(2 * 3_600)
        transport.respond(status: 200, body: Data(Self.fixture.utf8))
        let now = try await client.lookup(sha256: Self.hash)
        #expect(now.isKnown && !now.fromCache)
    }

    @Test func ignoresCorruptCacheFiles() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = VirusTotalCache(directory: dir)
        try Data("not json".utf8).write(to: dir.appending(path: "\(Self.hash).json"))
        #expect(cache.lookup(sha256: Self.hash) == nil)
    }

    @Test func validatesHashesBeforeAnyUse() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = StubTransport(status: 200)
        let client = try makeClient(transport, clock: TestClock(), cacheDirectory: dir)
        for bad in ["../../etc/passwd", "abc", Self.hash + "?x=1", String(repeating: "z", count: 64)] {
            await #expect(throws: VirusTotalError.invalidHash(bad)) { try await client.lookup(sha256: bad) }
            #expect(VirusTotalCache(directory: dir).fileURL(for: bad) == nil)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func refusesMalformedKeysAndNeverShowsTheKey() throws {
        #expect(throws: VirusTotalError.invalidAPIKey) { try VirusTotalClient(apiKey: "short", transport: StubTransport(status: 200)) }
        #expect(APIKeyStore.isValidVirusTotalKey(" \(Self.key)\n"))
        #expect(!APIKeyStore.isValidVirusTotalKey(String(Self.key.dropLast())))
        #expect(!APIKeyStore.isValidVirusTotalKey(String(repeating: "x", count: 64)))

        let client = try makeClient(StubTransport(status: 200), clock: TestClock(), cacheDirectory: nil)
        var dumped = ""
        dump(client, to: &dumped)
        #expect(!dumped.contains(Self.key))
        #expect(!String(reflecting: client).contains(Self.key))
    }

    @Test func allowsRedirectsOnlyToVirusTotalOverHTTPS() {
        func allows(_ url: String) -> Bool { RedirectGuard.allows(URLRequest(url: URL(string: url)!)) }
        #expect(allows("https://www.virustotal.com/api/v3/files/x"))
        #expect(allows("https://virustotal.com/x"))
        #expect(!allows("http://www.virustotal.com/api/v3/files/x"))
        #expect(!allows("https://evil.example/"))
        #expect(!allows("https://virustotal.com.evil.example/"))
        #expect(!allows("https://notvirustotal.com/"))
    }

    @Test func transportRefusesRedirectsOffHTTPS() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let transport = URLSessionVirusTotalTransport(configuration: configuration, timeout: 5)

        let insecure = URLRequest(url: URL(string: "https://www.virustotal.com/api/v3/files/insecure")!)
        await #expect(throws: VirusTotalError.redirectRejected) { try await transport.send(insecure) }

        let plain = URLRequest(url: URL(string: "http://www.virustotal.com/api/v3/files/x")!)
        await #expect(throws: VirusTotalError.insecureURL) { try await transport.send(plain) }

        let secure = URLRequest(url: URL(string: "https://www.virustotal.com/api/v3/files/secure")!)
        let (data, response) = try await transport.send(secure)
        #expect(response.statusCode == 200 && String(decoding: data, as: UTF8.self) == "final")
    }

    // MARK: Rate limiter

    @Test func waitsWhenTheMinuteBudgetIsSpent() async throws {
        let clock = TestClock()
        let limiter = VirusTotalRateLimiter(perMinute: 4, perDay: 500, now: { clock.now }, sleep: { clock.sleep($0) })
        for _ in 0..<4 {
            try await limiter.acquire()
            clock.advance(1)
        }
        #expect(clock.sleeps.isEmpty)
        try await limiter.acquire()  // The first slot frees 60 s after it was taken, 56 s from now.
        #expect(clock.sleeps == [56])
        #expect(await limiter.remainingToday == 495)
    }

    @Test func refusesBeyondTheDailyBudgetUntilTheNextDay() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_790_035_200))  // Midnight UTC.
        let limiter = VirusTotalRateLimiter(perMinute: 100, perDay: 3, now: { clock.now }, sleep: { clock.sleep($0) })
        for _ in 0..<3 { try await limiter.acquire() }
        await #expect(throws: VirusTotalError.dailyQuotaExhausted(limit: 3)) { try await limiter.acquire() }
        #expect(await limiter.remainingToday == 0)
        clock.advance(86_400)
        try await limiter.acquire()
        #expect(await limiter.remainingToday == 2)
    }

    @Test func persistsCountersAcrossInstances() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let state = dir.appending(path: "rate-limit.json")
        let first = VirusTotalRateLimiter(perMinute: 2, perDay: 10, stateURL: state, now: { clock.now }, sleep: { clock.sleep($0) })
        try await first.acquire()
        try await first.acquire()

        let second = VirusTotalRateLimiter(perMinute: 2, perDay: 10, stateURL: state, now: { clock.now }, sleep: { clock.sleep($0) })
        #expect(await second.remainingToday == 8)
        try await second.acquire()
        #expect(clock.sleeps == [60])
    }

    @Test func cacheHitsCostNoQuota() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let limiter = VirusTotalRateLimiter(perMinute: 4, perDay: 2, now: { clock.now }, sleep: { clock.sleep($0) })
        let client = try makeClient(StubTransport(status: 200, body: Data(Self.fixture.utf8)), clock: clock,
                                    cacheDirectory: dir, limiter: limiter)
        for _ in 0..<5 { _ = try await client.lookup(sha256: Self.hash) }
        #expect(await limiter.remainingToday == 1)
    }
}

/// Serves `…/insecure` as a redirect to plain HTTP and `…/secure` as a redirect to `…/final`.
private final class RedirectingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        let target: URL? = switch url.lastPathComponent {
        case "insecure": URL(string: "http://evil.example/steal")
        case "secure": URL(string: "https://www.virustotal.com/api/v3/files/final")
        default: nil
        }
        if let target {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // Only reached by the task when the redirect is refused: it then completes with the 302.
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data("final".utf8))
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
