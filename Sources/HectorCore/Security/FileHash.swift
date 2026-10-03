import CryptoKit
import Foundation

/// SHA-256 digests of files, as used to identify a binary with VirusTotal.
public enum FileHash {
    /// Read size per chunk. Large enough to keep syscalls rare, small enough that hashing a
    /// multi-gigabyte disk image never holds more than this in memory.
    static let chunkSize = 1 << 20

    public enum HashError: Error, CustomStringConvertible {
        case notARegularFile(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .notARegularFile(let path): "Not a regular file: \(path)"
            case .unreadable(let path): "Cannot read \(path)."
            }
        }
    }

    /// Lowercase hex SHA-256 of the file at `url`, read in chunks so the file is never loaded whole.
    public static func sha256(of url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HashError.unreadable(url.path)
        }
        // A bundle is a directory: callers must pick the file they mean (usually the main executable).
        guard !isDirectory.boolValue else { throw HashError.notARegularFile(url.path) }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw HashError.unreadable(url.path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// The file to hash for `url`: the main executable of a bundle, else the file itself.
    /// VirusTotal knows binaries, not folders.
    public static func hashTarget(for url: URL, signature: CodeSignatureInfo? = nil) -> URL {
        if let executable = signature?.mainExecutable { return URL(fileURLWithPath: executable) }
        if let executable = Bundle(url: url)?.executableURL { return executable }
        return url
    }

    /// Lowercase hex SHA-256 of in-memory data.
    public static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Whether `string` is a SHA-256 in hex (64 hex digits, any case). Checked before a hash is
    /// ever used in a file name or a URL, so it cannot smuggle `/`, `..` or query characters.
    public static func isValidSHA256(_ string: String) -> Bool {
        isHex(string, length: 64)
    }

    /// Whether `string` is exactly `length` ASCII hex digits.
    static func isHex(_ string: String, length: Int) -> Bool {
        string.utf8.count == length && string.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"),
                 UInt8(ascii: "A")...UInt8(ascii: "F"): true
            default: false
            }
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
