import Foundation
import Security

/// Authorization Services for the requests that change the firewall.
///
/// Being in the admin group only proves the caller runs as an administrator account, which any
/// process of that account does, malware included. Changing the rules therefore also requires an
/// authorization the user granted with their password (the system dialog), passed to the helper
/// as an external form and checked there without user interaction.
public enum HelperAuthorization {
    public static let rightName = "io.github.0xrd.netbite.modify-firewall"

    /// Administrator password, remembered for five minutes by the client that asked for it.
    static var rightDefinition: [String: Any] { [
        "class": "user",
        "group": "admin",
        "authenticate-user": true,
        "allow-root": true,
        "shared": false,
        "timeout": 300,
        "version": 1,
        "comment": "Change the Netbite firewall rules.",
    ] }

    public struct AuthorizationError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            status == errAuthorizationCanceled
                ? "Authorization was cancelled."
                : "Authorization failed (\(status)): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error")"
        }
    }

    // MARK: - Client side

    nonisolated(unsafe) private static var clientReference: AuthorizationRef?
    private static let lock = NSLock()

    /// Obtains the right, showing the system password dialog when the cached credential expired,
    /// and returns the external form to send with the request. Blocks: call it off the main thread.
    public static func externalForm() throws -> Data {
        try lock.withLock {
            if clientReference == nil {
                var reference: AuthorizationRef?
                let status = AuthorizationCreate(nil, nil, [], &reference)
                guard status == errAuthorizationSuccess, let reference else { throw AuthorizationError(status: status) }
                clientReference = reference
            }
            let reference = clientReference!
            let status = copyRight(reference, flags: [.interactionAllowed, .extendRights, .preAuthorize])
            guard status == errAuthorizationSuccess else { throw AuthorizationError(status: status) }
            var form = AuthorizationExternalForm()
            let made = AuthorizationMakeExternalForm(reference, &form)
            guard made == errAuthorizationSuccess else { throw AuthorizationError(status: made) }
            return withUnsafeBytes(of: &form) { Data($0) }
        }
    }

    // MARK: - Helper side

    /// True when `data` is an authorization that already holds the right. Never prompts.
    public static func verify(_ data: Data) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { _ = data.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess, let reference else { return false }
        defer { AuthorizationFree(reference, []) }
        return copyRight(reference, flags: [.extendRights]) == errAuthorizationSuccess
    }

    /// Adds the right to the authorization database. Root only; done at install and at launch.
    public static func defineRight() throws {
        var reference: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &reference)
        guard created == errAuthorizationSuccess, let reference else { throw AuthorizationError(status: created) }
        defer { AuthorizationFree(reference, []) }
        let status = AuthorizationRightSet(reference, rightName, rightDefinition as CFDictionary,
                                           "Netbite wants to change the firewall rules." as CFString, nil, nil)
        guard status == errAuthorizationSuccess else { throw AuthorizationError(status: status) }
    }

    public static func removeRight() {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return }
        defer { AuthorizationFree(reference, []) }
        AuthorizationRightRemove(reference, rightName)
    }

    private static func copyRight(_ reference: AuthorizationRef, flags: AuthorizationFlags) -> OSStatus {
        rightName.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
            }
        }
    }
}
