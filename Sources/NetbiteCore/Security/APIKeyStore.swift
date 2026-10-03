import Foundation
import Security

/// Keeps the VirusTotal API key in the user's login Keychain as a generic password, so it never
/// sits in a plain file, an environment variable or shell history.
///
/// The login (file-based) keychain is used rather than the data protection keychain because the
/// latter needs a keychain-access-groups entitlement that an unsigned CLI build does not have.
public struct APIKeyStore: Sendable {
    public static let virusTotalService = "io.github.0xrd.netbite.virustotal"

    public let service: String
    public let account: String

    public enum KeychainError: Error, CustomStringConvertible {
        case invalidFormat
        case unexpectedData
        case status(OSStatus)

        // Never includes the key itself.
        public var description: String {
            switch self {
            case .invalidFormat: "That does not look like a VirusTotal API key (64 hexadecimal characters)."
            case .unexpectedData: "The Keychain item holds something that is not an API key."
            case .status(let status):
                "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown") (\(status))"
            }
        }
    }

    public init(service: String = virusTotalService, account: String = "api-key") {
        self.service = service
        self.account = account
    }

    /// Whether `key` has the shape of a VirusTotal API key: 64 hex digits, surrounding whitespace ignored.
    public static func isValidVirusTotalKey(_ key: String) -> Bool {
        FileHash.isHex(key.trimmingCharacters(in: .whitespacesAndNewlines), length: 64)
    }

    /// The stored key, or `nil` when none is stored.
    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return key
    }

    /// Validates then stores `key`, replacing any previous one.
    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidVirusTotalKey(trimmed) else { throw KeychainError.invalidFormat }
        let data = Data(trimmed.utf8)

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Netbite VirusTotal API key"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.status(update) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    /// Removes the stored key. Returns `false` when there was none.
    @discardableResult
    public func delete() throws -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return true
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
