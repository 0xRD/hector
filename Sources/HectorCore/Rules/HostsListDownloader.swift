import Foundation

/// Downloads a hosts list from the built-in catalog, with the bounds of `HostsListCatalog`.
///
/// The privileged helper uses it as root, so everything from the network is untrusted: HTTPS only,
/// redirects only to HTTPS on the same host, a size cap enforced while the body arrives, short
/// timeouts, and a strict parse whose result must look plausible before it replaces anything.
public enum HostsListDownloader {
    public enum Outcome: Sendable {
        /// The server answered 304: the copy in force is current.
        case notModified
        /// A new copy, parsed and validated.
        case downloaded(HostsListParseResult, etag: String?, lastModified: String?)
    }

    public enum DownloadError: Error, CustomStringConvertible, Equatable {
        case notHTTPS
        case badStatus(Int)
        case tooLarge(limit: Int)
        case notText
        case implausible(domains: Int, minimum: Int)
        case tooManyDomains(limit: Int)

        public var description: String {
            switch self {
            case .notHTTPS: "The server did not answer over HTTPS on the expected host."
            case .badStatus(let code): "The server answered HTTP \(code)."
            case .tooLarge(let limit): "The list is larger than \(limit / (1024 * 1024)) MB; it was not installed."
            case .notText: "The download is not a UTF-8 text file; it was not installed."
            case .implausible(let domains, let minimum):
                "The download holds \(domains) valid domains, fewer than the \(minimum) expected; it was not installed."
            case .tooManyDomains(let limit): "The list has more than \(limit) domains; it was not installed."
            }
        }
    }

    /// Follows a redirect only when it stays on HTTPS and on the host of the catalog URL.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        let allowedHost: String

        init(allowedHost: String) {
            self.allowedHost = allowedHost
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, url.scheme == "https", url.host()?.lowercased() == allowedHost else { return nil }
            return request
        }
    }

    /// Downloads `source` (conditionally, when validators of the copy in force are given), then
    /// parses and validates it. Throws instead of returning anything doubtful.
    public static func fetch(_ source: HostsListSource, etag: String?, lastModified: String?) async throws -> Outcome {
        guard source.url.scheme == "https", let host = source.url.host()?.lowercased() else { throw DownloadError.notHTTPS }

        var request = URLRequest(url: source.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Hector/\(HectorVersion.current)", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = HostsListCatalog.requestTimeout
        configuration.timeoutIntervalForResource = HostsListCatalog.resourceTimeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(allowedHost: host), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, finalURL.scheme == "https",
              finalURL.host()?.lowercased() == host else {
            bytes.task.cancel()
            throw DownloadError.notHTTPS
        }
        if http.statusCode == 304 {
            bytes.task.cancel()
            return .notModified
        }
        guard http.statusCode == 200 else {
            bytes.task.cancel()
            throw DownloadError.badStatus(http.statusCode)
        }
        let limit = HostsListCatalog.maximumDownloadSize
        if http.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw DownloadError.tooLarge(limit: limit)
        }

        var data = Data()
        data.reserveCapacity(min(Int(max(http.expectedContentLength, 0)), limit))
        for try await byte in bytes {
            guard data.count < limit else {
                bytes.task.cancel()
                throw DownloadError.tooLarge(limit: limit)
            }
            data.append(byte)
        }

        let result = try validate(data, for: source)
        let newETag = http.value(forHTTPHeaderField: "ETag").flatMap(validator)
        let newLastModified = http.value(forHTTPHeaderField: "Last-Modified").flatMap(validator)
        return .downloaded(result, etag: newETag, lastModified: newLastModified)
    }

    /// Parses a downloaded list and refuses it unless it looks like the real thing.
    public static func validate(_ data: Data, for source: HostsListSource) throws -> HostsListParseResult {
        guard let text = String(data: data, encoding: .utf8) else { throw DownloadError.notText }
        let result = HostsListParser.parse(text)
        if result.exceededLimit { throw DownloadError.tooManyDomains(limit: HostsListCatalog.maximumDomainsPerList) }
        guard result.domains.count >= source.minimumDomains else {
            throw DownloadError.implausible(domains: result.domains.count, minimum: source.minimumDomains)
        }
        return result
    }

    /// A validator is echoed back in a header later: keep it short and printable.
    public static func validator(_ value: String) -> String? {
        guard (1...256).contains(value.utf8.count), value.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return value
    }
}
