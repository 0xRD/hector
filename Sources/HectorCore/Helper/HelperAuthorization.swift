import Foundation
import Security

/// Authorization Services for the requests that change the firewall, and for reading what root
/// keeps to itself.
///
/// Being in the admin group only proves the caller runs as an administrator account, which any
/// process of that account does, malware included. Changing the rules therefore also requires an
/// authorization the user granted with their password (the system dialog), passed to the helper
/// as an external form and checked there without user interaction.
public enum HelperAuthorization {
    /// One thing the helper only does for a client the user approved with their password.
    public struct Right: Sendable, Equatable {
        public let name: String
        let comment: String
        /// Shown in the system dialog.
        let prompt: String

        /// `apply`, `flush` and `refreshHostsLists`.
        public static let modifyFirewall = Right(name: "io.github.0xrd.hector.modify-firewall",
                                                 comment: "Change the Hector firewall rules.",
                                                 prompt: "Hector wants to change the firewall rules.")
        /// The text of root's entries in `rootPersistence`: cron commands, login hooks, the
        /// comments and forced commands of root's SSH keys.
        public static let readRootPersistence = Right(name: "io.github.0xrd.hector.read-root-persistence",
                                                      comment: "Read root's cron jobs, login hooks and SSH key details.",
                                                      prompt: "Hector wants to show root's cron jobs, login hooks and SSH key details.")

        public static let all = [modifyFirewall, readRootPersistence]

        /// Administrator password, remembered for five minutes by the client that asked for it.
        var definition: [String: Any] { [
            "class": "user",
            "group": "admin",
            "authenticate-user": true,
            "allow-root": true,
            "shared": false,
            "timeout": 300,
            "version": 1,
            "comment": comment,
        ] }
    }

    public static let rightName = Right.modifyFirewall.name

    public struct AuthorizationError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            status == errAuthorizationCanceled
                ? "Authorization was cancelled."
                : "Authorization failed (\(status)): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error")"
        }
    }

    // MARK: - Client side

    /// One authorization per right, so that this process does not send, with a request to read,
    /// an authorization that could also change the firewall. This is tidiness on the client's
    /// side, not a boundary: both rights ask for the same thing (an administrator's password),
    /// and macOS may let an authorization that obtained one extend to the other within the five
    /// minutes. A process the user typed their password for is trusted with both.
    nonisolated(unsafe) private static var clientReferences: [String: AuthorizationRef] = [:]
    private static let lock = NSLock()

    /// Obtains the right, showing the system password dialog when the cached credential expired,
    /// and returns the external form to send with the request. Blocks: call it off the main thread.
    public static func externalForm(for right: Right = .modifyFirewall) throws -> Data {
        try externalForm(for: right, flags: [.interactionAllowed, .extendRights, .preAuthorize])
    }

    /// The external form when this process still holds the right (the password was typed less
    /// than five minutes ago), `nil` otherwise. Never shows a dialog.
    public static func heldExternalForm(for right: Right) -> Data? {
        try? externalForm(for: right, flags: [.extendRights])
    }

    private static func externalForm(for right: Right, flags: AuthorizationFlags) throws -> Data {
        try lock.withLock {
            if clientReferences[right.name] == nil {
                var reference: AuthorizationRef?
                let status = AuthorizationCreate(nil, nil, [], &reference)
                guard status == errAuthorizationSuccess, let reference else { throw AuthorizationError(status: status) }
                clientReferences[right.name] = reference
            }
            let reference = clientReferences[right.name]!
            let status = copyRight(right, reference, flags: flags)
            guard status == errAuthorizationSuccess else { throw AuthorizationError(status: status) }
            var form = AuthorizationExternalForm()
            let made = AuthorizationMakeExternalForm(reference, &form)
            guard made == errAuthorizationSuccess else { throw AuthorizationError(status: made) }
            return withUnsafeBytes(of: &form) { Data($0) }
        }
    }

    // MARK: - Helper side

    /// True when `data` is an authorization that already holds `right`. Never prompts.
    public static func verify(_ data: Data, right: Right = .modifyFirewall) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { _ = data.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess, let reference else { return false }
        defer { AuthorizationFree(reference, []) }
        return copyRight(right, reference, flags: [.extendRights]) == errAuthorizationSuccess
    }

    /// Adds Hector's rights to the authorization database. Root only; done at install and at launch.
    public static func defineRights() throws {
        var reference: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &reference)
        guard created == errAuthorizationSuccess, let reference else { throw AuthorizationError(status: created) }
        defer { AuthorizationFree(reference, []) }
        for right in Right.all {
            let status = AuthorizationRightSet(reference, right.name, right.definition as CFDictionary, right.prompt as CFString, nil, nil)
            guard status == errAuthorizationSuccess else { throw AuthorizationError(status: status) }
        }
    }

    public static func removeRights() {
        for right in Right.all { removeRight(named: right.name) }
    }

    public static func removeRight(named name: String) {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return }
        defer { AuthorizationFree(reference, []) }
        AuthorizationRightRemove(reference, name)
    }

    private static func copyRight(_ right: Right, _ reference: AuthorizationRef, flags: AuthorizationFlags) -> OSStatus {
        right.name.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
            }
        }
    }
}
