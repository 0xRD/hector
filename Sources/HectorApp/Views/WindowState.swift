import HectorCore
import Observation

/// What the user picked or points at in the main window.
///
/// Kept in an observable object owned by the app rather than in `@State`: in the macOS 27 SDK
/// `@State` is a macro whose plugin ships only with Xcode, and Hector must build with the
/// Command Line Tools alone.
@MainActor
@Observable
final class WindowState {
    var sidebarSelection: SidebarItem? = .allApps
    /// The app the Connections screen is narrowed to; `nil` shows every app.
    var appFilter: AppGroup.ID?
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

    /// Records that the pointer entered or left a row of the destination list.
    ///
    /// The change is applied on the next turn of the main actor, not inside the callback: a
    /// `List` row's hover handler can run while AppKit's NSTableView is still adding or laying out
    /// its rows (the pointer is already over the window at launch, and rows arrive every second).
    /// Writing `hovered` there invalidates the window, and SwiftUI then updates both tables from
    /// inside their own delegate call, which AppKit reports as "reentrant operation in its
    /// NSTableView delegate". Redundant writes are skipped too: with the Swift 6.1 toolchain, an
    /// `@Observable` property can notify its observers even when the value does not change.
    func hoverListRow(_ ref: DestinationRef, inside: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if inside {
                if self.hovered != ref { self.hovered = ref }
            } else if self.hovered == ref {
                self.hovered = nil
            }
        }
    }
}

enum UninstallPhase: Equatable {
    case confirm
    case working
    case failed(String)
}
