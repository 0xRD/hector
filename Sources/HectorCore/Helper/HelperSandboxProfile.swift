import Darwin
import Foundation

/// The sandbox profile `hectord serve` applies to itself (see Sources/hectord/Sandbox.swift).
///
/// Root can normally write anywhere and start anything. Under this profile the helper, and every
/// child it starts (children inherit the sandbox), may only write to its own data folder,
/// /etc/hosts, its socket and log, the private folders of its download children and /dev/pf, and
/// may only start pfctl, dscacheutil, killall, sfltool and itself. A compromised helper can no
/// longer install a LaunchDaemon, replace a binary or edit sudoers. Reading stays allowed: listing
/// processes and sockets is what the helper is for.
public enum HelperSandboxProfile {
    /// The only executables the helper starts, by absolute path (see `Enforcer.run`,
    /// `respond(to:)` and `Unprivileged`).
    public static let allowedExecutables = ["/sbin/pfctl", "/usr/bin/dscacheutil", "/usr/bin/killall", "/usr/bin/sfltool"]

    /// Prefix of the folders `Unprivileged` creates for its download children.
    public static let fetchFolderPrefix = "/private/var/tmp/hectord-fetch."

    /// The profile, in the Sandbox Profile Language. A dry run may write anything under
    /// `dryRunRoot` instead of the system paths. Paths are real paths (/private/etc, not /etc):
    /// the sandbox matches them after symlinks are resolved.
    public static func source(executable: String, dryRunRoot: String?, socketPath: String) -> String {
        let socket = realPath(socketPath)
        var filters: [String]
        if let dryRunRoot {
            filters = ["(subpath \(quoted(realPath(dryRunRoot))))", "(literal \(quoted(socket)))"]
        } else {
            filters = [
                "(subpath \(quoted(HelperPaths.dataDirectory)))",
                "(literal \"/private/etc/hosts\")",
                // `SecureFiles.write` renames a temporary sibling over the file.
                "(prefix \"/private/etc/hosts.hector-\")",
                "(literal \(quoted(socket)))",
                "(literal \(quoted(HelperPaths.logFile)))",
                "(literal \"/dev/pf\")",
            ]
        }
        filters += ["(literal \"/dev/null\")", "(prefix \(quoted(fetchFolderPrefix)))"]
        let executables = (allowedExecutables + [realPath(executable)]).map { "(literal \(quoted($0)))" }
        return """
        (version 1)
        (allow default)
        (deny file-write*)
        (allow file-write*
            \(filters.joined(separator: "\n    ")))
        (deny file-write-setugid)
        (deny process-exec*)
        (allow process-exec*
            \(executables.joined(separator: "\n    ")))
        """
    }

    /// `path` with symlinks resolved, so /var/run/x and /tmp/x become /private/..., even when the
    /// last component does not exist yet (the socket before `bind`).
    public static func realPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty, let resolved = realpath(parent, nil) else { return path }
        defer { free(resolved) }
        return (String(cString: resolved) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// A string literal for the profile: a path cannot close the string and add rules.
    public static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
