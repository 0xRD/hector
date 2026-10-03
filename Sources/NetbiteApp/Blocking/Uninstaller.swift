import AppKit
import Foundation
import NetbiteCore
import Security

/// Removes Netbite from this Mac without leaving anything behind.
///
/// System side (needs the administrator password once): the helper's rules, LaunchDaemon, binary,
/// data, logs and authorization right, through `netbited uninstall --purge`.
/// User side: blocklist and GeoIP copy, preferences, caches, saved window state, the VirusTotal key
/// in the Keychain, then the app itself goes to the Trash.
@MainActor
enum Uninstaller {
    /// Identifier used for preferences, caches and the Keychain; constant so that a copy run with
    /// `swift run` cleans the same places as the bundled app.
    static let bundleIdentifier = "io.github.0xrd.netbite"
    static let keychainServices = ["io.github.0xrd.netbite.virustotal"]

    static var systemItems: [String] {
        [HelperPaths.launchDaemonPlist, HelperPaths.installedBinary, HelperPaths.dataDirectory,
         (HelperPaths.logFile as NSString).deletingLastPathComponent, HelperPaths.socket]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static var userItems: [URL] {
        let library = URL.libraryDirectory
        return [
            URL.applicationSupportDirectory.appending(path: "Netbite"),
            library.appending(path: "Caches/\(bundleIdentifier)"),
            library.appending(path: "HTTPStorages/\(bundleIdentifier)"),
            library.appending(path: "HTTPStorages/\(bundleIdentifier).binarycookies"),
            library.appending(path: "Saved Application State/\(bundleIdentifier).savedState"),
            library.appending(path: "Preferences/\(bundleIdentifier).plist"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The running app, when it is a real bundle that can go to the Trash.
    static var appBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    enum Outcome {
        case done
        case cancelled
        case failed(String)
    }

    /// Runs the whole uninstall. Stops before touching user data if the administrator step was
    /// cancelled or failed, so a half-uninstalled Netbite never keeps rules without its app.
    static func uninstall() async -> Outcome {
        if !systemItems.isEmpty {
            guard let helper = helperBinary else { return .failed("netbited was not found; run `sudo netbited uninstall --purge`.") }
            // The logs are also removed by a fixed path, so an older installed helper that does not
            // know --purge leaves nothing behind either.
            let logDirectory = AdministratorScript.shellQuoted((HelperPaths.logFile as NSString).deletingLastPathComponent)
            switch AdministratorScript.run("\(AdministratorScript.shellQuoted(helper)) uninstall --purge; /bin/rm -rf \(logDirectory)") {
            case .success: break
            case .cancelled: return .cancelled
            case .failure(let message): return .failed(message)
            }
            if !systemItems.filter({ $0 != HelperPaths.socket }).isEmpty {
                return .failed("Some system files remain: \(systemItems.joined(separator: ", "))")
            }
        }

        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        for service in keychainServices {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        }
        for url in userItems {
            try? FileManager.default.removeItem(at: url)
        }
        if let app = appBundle {
            _ = try? await NSWorkspace.shared.recycle([app])
        }
        return .done
    }

    /// The installed helper first: it is root-owned, so a process of the user cannot have swapped
    /// it, unlike the copy inside the app bundle, which is only used when nothing is installed.
    private static var helperBinary: String? {
        let candidates: [String?] = [
            HelperPaths.installedBinary,
            Bundle.main.bundleURL.appending(path: "Contents/Helpers/netbited").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "netbited").path,
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// `do shell script … with administrator privileges`: macOS shows its own password dialog.
@MainActor
enum AdministratorScript {
    enum Result {
        case success
        case cancelled
        case failure(String)
    }

    static func run(_ command: String) -> Result {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return .success }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failure((error[NSAppleScript.errorMessage] as? String) ?? "The command failed.")
    }

    /// Single quotes for the shell, with embedded quotes closed, escaped and reopened.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
