import Darwin
import Foundation
import Testing
@testable import HectorCore

/// Regression tests for the issues found in the 0.3 security review (see SECURITY.md).
@Suite struct SecurityHardeningTests {
    // MARK: Log injection

    @Test func logLinesCannotBeForged() {
        let hostile = "evil.example\n2026-10-03T00:00:00Z Applied: fake line\r\u{1B}[31m\u{202E}"
        let clean = LogText.sanitized(hostile)
        #expect(!clean.contains("\n"))
        #expect(!clean.contains("\r"))
        #expect(!clean.contains("\u{1B}"))
        #expect(!clean.contains("\u{202E}"))
        #expect(clean.hasPrefix("evil.example\\n2026"))
    }

    @Test func logLinesAreBounded() {
        let clean = LogText.sanitized(String(repeating: "a", count: 10_000))
        #expect(clean.count <= LogText.maximumLength + 1)
    }

    // MARK: Authorization

    @Test func forgedAuthorizationsAreRejected() {
        #expect(!HelperAuthorization.verify(Data()))
        #expect(!HelperAuthorization.verify(Data(repeating: 0, count: 32)))
        #expect(!HelperAuthorization.verify(Data((0..<32).map { _ in UInt8.random(in: 0...255) })))
        #expect(!HelperAuthorization.verify(Data(repeating: 1, count: 64)))
    }

    // MARK: Input validation

    @Test func invalidCountryCodesAreRejectedWhenDecoding() {
        for bad in [#"["C"]"#, #"["CHN"]"#, #"["1A"]"#, #"["É1"]"#, #"["C\nN"]"#] {
            let json = Data(#"{"schemaVersion":1,"rules":[],"blockedCountries":\#(bad)}"#.utf8)
            #expect(throws: DecodingError.self, "\(bad)") { try JSONDecoder.hector.decode(Blocklist.self, from: json) }
        }
        let good = Data(#"{"schemaVersion":1,"rules":[],"blockedCountries":["cn","RU"]}"#.utf8)
        #expect(throws: Never.self) { try JSONDecoder.hector.decode(Blocklist.self, from: good) }
    }

    @Test func domainsCannotInjectHostsLines() {
        #expect(RuleTarget("evil.example\n0.0.0.0 apple.com") == nil)
        #expect(RuleTarget("evil.example 1.2.3.4") == nil)
        #expect(RuleTarget("#comment") == nil)
    }

    @Test func helperRejectsOversizedBlocklists() {
        let many = (0..<(HelperLimits.maximumRules + 1)).map { i in
            Rule(target: .network(CIDR(.v4(0x0B00_0000 + UInt32(i))))) // 11.0.0.0 + i
        }
        #expect(throws: HelperLimits.Violation.self) { try HelperLimits.validate(Blocklist(rules: many)) }

        let longNote = Blocklist(rules: [Rule(target: RuleTarget("example.com")!, note: String(repeating: "x", count: 501))])
        #expect(throws: HelperLimits.Violation.self) { try HelperLimits.validate(longNote) }

        #expect(throws: Never.self) { try HelperLimits.validate(BlockMatcherTests.blocklist) }
    }

    // MARK: Forged GeoIP data

    @Test func aForgedCountryCannotBlockTheInternetOrTheLAN() throws {
        let forged = """
        0.0.0.0,255.255.255.255,XX
        10.0.0.0,10.255.255.255,YY
        192.168.1.0,192.168.1.255,YY
        8.8.8.0,8.8.8.255,YY
        ::,ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff,XX

        """
        let geo = try GeoIPDatabase(csv: Data(forged.utf8))
        let compiled = RuleCompiler.compile(Blocklist(blockedCountries: ["XX", "YY"]), geo: geo)
        #expect(compiled.geoTable.map(\.description) == ["8.8.8.0/24"])
        #expect(compiled.warnings.contains { $0.contains("XX") })
    }

    // MARK: Socket reads

    @Test func aSlowClientIsCutOffByTheDeadline() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = "{\"stat".withCString { write(fds[1], $0, 6) }  // no newline, then silence
        let start = Date()
        #expect(throws: LineSocket.SocketError.self) {
            try LineSocket.readLine(from: fds[0], deadline: Date().addingTimeInterval(0.5))
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func anOversizedMessageIsRefused() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let payload = [UInt8](repeating: UInt8(ascii: "a"), count: 2_000) + [UInt8(ascii: "\n")]
        _ = payload.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        #expect(throws: LineSocket.SocketError.self) { try LineSocket.readLine(from: fds[0], maximumSize: 1_000) }
    }
}
