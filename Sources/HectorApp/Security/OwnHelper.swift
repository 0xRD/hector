import Foundation
import HectorCore

/// Hector's own helper in the Persistence list. It is ad hoc signed like every Hector build, so its
/// signature says nothing; comparing it with the helper inside this app does.
@MainActor
enum OwnHelper {
    static func isOwnHelper(_ item: PersistenceItem) -> Bool {
        item.label == HelperPaths.label || item.configurationPath == HelperPaths.launchDaemonPlist
    }

    private static var cache: (modified: Date, matches: Bool?)?

    /// `true` when the installed helper is byte for byte the one inside this app, `false` when it
    /// differs (an older version, or something else), `nil` when either cannot be read.
    static func matchesThisApp() -> Bool? {
        let installed = URL(fileURLWithPath: HelperPaths.installedBinary)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: installed.path))?[.modificationDate] as? Date else {
            return nil
        }
        if let cache, cache.modified == modified { return cache.matches }
        var matches: Bool?
        if let bundled = BlockingController.bundledHelper,
           let a = try? FileHash.sha256(of: installed), let b = try? FileHash.sha256(of: bundled) {
            matches = a == b
        }
        cache = (modified, matches)
        return matches
    }

    /// One line for the list and the detail panel.
    static func verdict() -> (text: String, isExpected: Bool) {
        switch matchesThisApp() {
        case true?: ("Hector's helper, identical to the one in this app", true)
        case false?: ("Hector's helper, but not the one in this app: update it from Blocklists", false)
        case nil: ("Hector's helper", true)
        }
    }
}
