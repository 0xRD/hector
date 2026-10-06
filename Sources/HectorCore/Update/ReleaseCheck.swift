import Foundation

/// The newest published release of Hector.
public struct HectorRelease: Codable, Equatable, Sendable {
    /// "0.4.9", without the tag's "v".
    public var version: String
    /// Its page on GitHub, with the release notes and the zip.
    public var page: URL

    public init(version: String, page: URL) {
        self.version = version
        self.page = page
    }
}

public enum ReleaseCheckError: Error, Equatable, CustomStringConvertible {
    case httpStatus(Int)
    case redirectRejected
    case malformedResponse
    case transport(String)

    public var description: String {
        switch self {
        case .httpStatus(let code): "GitHub answered with HTTP status \(code)."
        case .redirectRejected: "GitHub answered with a redirect, which is refused."
        case .malformedResponse: "GitHub sent an answer that could not be understood."
        case .transport(let message): "Could not reach GitHub: \(message)"
        }
    }
}

/// Asks GitHub for the number of Hector's latest release, only when the user turned the check on.
///
/// One unauthenticated GET to a fixed address, with no cookie, no cache and nothing about the Mac
/// in it; redirects are refused. Nothing is downloaded or installed: the app only says that a
/// newer version exists and how to get it.
public enum ReleaseCheck {
    public static let latestURL = URL(string: "https://api.github.com/repos/0xRD/hector/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/0xRD/hector/releases")!

    /// The release in an answer of GitHub's "latest release" API; `nil` for a draft, a
    /// prerelease or a tag that is not a version number. The page falls back to the list of
    /// releases unless it is one of Hector's release pages on github.com.
    public static func parse(_ data: Data) -> HectorRelease? {
        struct Answer: Decodable {
            var tag_name: String
            var html_url: String?
            var draft: Bool?
            var prerelease: Bool?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              answer.draft != true, answer.prerelease != true else { return nil }
        let version = answer.tag_name.hasPrefix("v") ? String(answer.tag_name.dropFirst()) : answer.tag_name
        guard components(version) != nil else { return nil }
        var page = releasesPage
        if let link = answer.html_url.flatMap(URL.init(string:)), link.scheme == "https", link.host() == "github.com",
           link.path().hasPrefix("/0xRD/hector/releases/") {
            page = link
        }
        return HectorRelease(version: version, page: page)
    }

    /// `true` when `candidate` is a later version than `current` ("0.4.10" > "0.4.9" > "0.4").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// "0.4.9" → [0, 4, 9]; `nil` unless it is one to four numbers separated by dots.
    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 6, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        return numbers.count == parts.count ? numbers : nil
    }

    /// Fetches the latest release from GitHub.
    public static func fetchLatest(timeout: TimeInterval = 15) async throws -> HectorRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hector/\(HectorVersion.current)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReleaseCheckError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ReleaseCheckError.malformedResponse }
        if (300..<400).contains(http.statusCode) { throw ReleaseCheckError.redirectRejected }
        guard http.statusCode == 200 else { throw ReleaseCheckError.httpStatus(http.statusCode) }
        guard data.count < 1 << 20, let release = parse(data) else { throw ReleaseCheckError.malformedResponse }
        return release
    }
}

/// The address is fixed: any redirect is refused.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
