import NetbiteCore
import Observation

/// What the user picked or points at in the main window.
///
/// Kept in an observable object owned by the app rather than in `@State`: in the macOS 27 SDK
/// `@State` is a macro whose plugin ships only with Xcode, and Netbite must build with the
/// Command Line Tools alone.
@MainActor
@Observable
final class WindowState {
    var sidebarSelection: SidebarItem? = .allApps
    var selectedDestination: DestinationRef?
    /// Destination under the pointer, on the map or in the list.
    var hovered: DestinationRef?
    var filter: DestinationFilter = .all
    var search = ""
    var showInspector = true
    // Blocklists screen
    var countrySearch = ""
    var showAllCountries = false
    var newRule = ""
    var newRuleNote = ""
    var showUninstall = false
    var uninstallPhase = UninstallPhase.confirm
    // Security screens
    var selectedPersistenceItem: PersistenceItem.ID?
    var selectedProcess: RunningProcess.ID?
    var processesFlaggedOnly = false
    var processesAsTree = true
    // Settings
    var apiKeyDraft = ""
}

enum UninstallPhase: Equatable {
    case confirm
    case working
    case failed(String)
}
