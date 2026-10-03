import Foundation

/// Moves what Netbite 0.3 left in the user's account to Hector's names, once. Run at launch by the
/// app and the CLI; it does nothing when there is nothing left to move.
public enum LegacyMigration {
    /// `~/Library/Application Support/Hector`.
    public static var userDataDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Hector", directoryHint: .isDirectory)
    }

    static var legacyUserDataDirectory: URL {
        URL.applicationSupportDirectory.appending(path: LegacyPaths.userDataFolder, directoryHint: .isDirectory)
    }

    /// Returns what was moved, for a log line; empty when nothing was.
    @discardableResult
    public static func run() -> [String] {
        var moved: [String] = []
        if moveUserData(from: legacyUserDataDirectory, to: userDataDirectory) { moved.append("data folder") }
        if moveAPIKey(from: APIKeyStore(service: LegacyPaths.keychainService), to: APIKeyStore()) { moved.append("VirusTotal key") }
        return moved
    }

    /// Renames `legacy` to `current` when only the legacy folder exists.
    static func moveUserData(from legacy: URL, to current: URL) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.path), !files.fileExists(atPath: current.path) else { return false }
        do {
            try files.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: legacy, to: current)
            return true
        } catch {
            return false
        }
    }

    /// Copies the key to the new Keychain item, then deletes the old one. macOS may ask once whether
    /// Hector may read the item Netbite created.
    static func moveAPIKey(from legacy: APIKeyStore, to current: APIKeyStore) -> Bool {
        // Attributes only until there is something to move: reading a key can prompt.
        guard (try? legacy.exists()) == true, (try? current.exists()) == false,
              let key = try? legacy.read() else { return false }
        do {
            try current.save(key)
            try legacy.delete()
            return true
        } catch {
            return false
        }
    }
}
