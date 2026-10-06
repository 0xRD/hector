import AppKit
import HectorCore
import Observation

/// Tells the user when a newer Hector is out, only if they agreed to it.
///
/// Off by default. At the first launch the main window asks once whether to check; the answer can
/// be changed in Settings. When on, Hector asks GitHub for the latest release number at most once
/// a week (see `ReleaseCheck`). It never downloads or installs anything: it says which version is
/// out and how to get it, with Homebrew or from the release page.
@MainActor
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(HectorRelease)
        case failed(String)
    }

    private enum Key {
        static let enabled = "updateCheckEnabled"
        static let answered = "updateCheckAnswered"
        static let lastCheck = "updateCheckLast"
        static let latest = "updateCheckLatest"
    }

    private static let interval: TimeInterval = 7 * 86_400

    private(set) var status: Status = .idle
    private(set) var lastCheck: Date?
    /// The user answered the first-launch question (either way).
    private(set) var hasAnswered: Bool

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            hasAnswered = true
            UserDefaults.standard.set(true, forKey: Key.answered)
            if isEnabled { Task { await checkIfDue() } }
        }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        hasAnswered = defaults.bool(forKey: Key.answered)
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
        // A release found earlier stays announced until it is installed.
        if isEnabled, let data = defaults.data(forKey: Key.latest),
           let release = try? JSONDecoder().decode(HectorRelease.self, from: data),
           ReleaseCheck.isNewer(release.version, than: HectorVersion.current) {
            status = .available(release)
        }
    }

    /// `HECTOR_DEMO=1` and the scripted snapshots (debug builds) never ask and never check.
    private var isScripted: Bool {
        #if DEBUG
        DemoData.isEnabled || ProcessInfo.processInfo.environment["HECTOR_SNAPSHOT"] != nil
        #else
        false
        #endif
    }

    /// The first-launch question is still to be asked.
    var needsAnswer: Bool { !hasAnswered && !isScripted }

    var availableRelease: HectorRelease? {
        if case .available(let release) = status { return release }
        return nil
    }

    /// Records the answer to the first-launch question.
    func answer(enable: Bool) {
        hasAnswered = true
        UserDefaults.standard.set(true, forKey: Key.answered)
        isEnabled = enable
    }

    /// Checks now and then every few hours whether a week has passed, while Hector runs.
    func start() {
        guard loop == nil, !isScripted else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Checks when the user turned the check on and the last one is a week old.
    func checkIfDue() async {
        guard isEnabled, !isScripted else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        await checkNow()
    }

    /// Asks GitHub now, whatever the setting: the user clicked "Check Now".
    func checkNow() async {
        guard status != .checking, !isScripted else { return }
        status = .checking
        do {
            let release = try await ReleaseCheck.fetchLatest()
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Key.lastCheck)
            if ReleaseCheck.isNewer(release.version, than: HectorVersion.current) {
                status = .available(release)
                UserDefaults.standard.set(try? JSONEncoder().encode(release), forKey: Key.latest)
            } else {
                status = .upToDate
                UserDefaults.standard.removeObject(forKey: Key.latest)
            }
        } catch {
            status = .failed((error as? ReleaseCheckError)?.description ?? error.localizedDescription)
        }
    }

    /// Hector came from the Homebrew cask: updating is `brew upgrade hector`.
    static var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/hector", "/usr/local/Caskroom/hector"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Says which version is out and how to get it.
    static func presentAvailable(_ release: HectorRelease) {
        let alert = NSAlert()
        alert.messageText = "Hector \(release.version) is available"
        if installedWithHomebrew {
            alert.informativeText = "You have \(HectorVersion.current). Hector was installed with Homebrew: run "
                + "\u{201C}brew upgrade hector\u{201D} in Terminal to update. The helper and your rules stay in place."
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew upgrade hector", forType: .string)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(release.page)
            default:
                break
            }
        } else {
            alert.informativeText = "You have \(HectorVersion.current). Download the new zip from its release page, "
                + "then replace Hector in Applications. The helper and your rules stay in place."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
        }
    }

    /// "Check for Updates…" in the app menu: checks, then tells the result whatever it is.
    func checkFromMenu() async {
        await checkNow()
        switch status {
        case .available(let release):
            Self.presentAvailable(release)
        case .upToDate:
            let alert = NSAlert()
            alert.messageText = "Hector is up to date"
            alert.informativeText = "\(HectorVersion.current) is the latest version."
            alert.runModal()
        case .failed(let message):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Hector could not check for updates"
            alert.informativeText = message
            alert.runModal()
        case .idle, .checking:
            break
        }
    }
}
