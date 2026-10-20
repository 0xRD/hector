import Foundation
import HectorCore

/// Connects what Hector watches to the notifications the user turned on: camera and microphone
/// events, new active keyboard taps, new persistence items and apps connecting for the first time.
///
/// Costs nothing for a kind that is off: no tap polling, no folder watch, no bookkeeping of apps.
@MainActor
final class AlertWatcher {
    private var notifier: Notifier?
    private var security: SecurityController?
    private var privacy: PrivacyController?
    private var monitor: ConnectionMonitor?

    private var folderWatcher: FolderWatcher?
    private var persistenceLoop: Task<Void, Never>?
    private var tapsLoop: Task<Void, Never>?

    private let knownAppsFile = KnownSetFile(named: "known-apps")
    private lazy var knownApps = knownAppsFile.load()
    private var knownAppsChanged = false
    private var knownAppsSavedAt = Date.distantPast
    private let knownTapsFile = KnownSetFile(named: "known-keyboard-taps")
    private lazy var knownTaps = knownTapsFile.load()
    /// The first check of a launch saves the baseline even when nothing is new.
    private var tapsSaved = false

    /// Rescans when launch folders change, and every hour for what has no folder to watch
    /// (login items, extensions, profiles).
    private static let persistenceInterval: Duration = .seconds(3600)
    private static let tapsInterval: Duration = .seconds(30)

    /// Wires the sources once; later calls do nothing.
    func start(notifier: Notifier, security: SecurityController, privacy: PrivacyController, monitor: ConnectionMonitor) {
        guard self.notifier == nil else { return }
        #if DEBUG
        if DemoData.isEnabled { return }
        #endif
        self.notifier = notifier
        self.security = security
        self.privacy = privacy
        self.monitor = monitor
        privacy.onEvents = { [weak self] events in self?.captureEvents(events) }
        security.onNewPersistenceItems = { [weak self] items in self?.newPersistenceItems(items) }
        notifier.onSettingsChange = { [weak self] in self?.update() }
        update()
    }

    /// Starts or stops each watch to match the settings.
    private func update() {
        guard let notifier, let monitor else { return }

        if notifier.isEnabled(.persistence) {
            if persistenceLoop == nil {
                let watcher = FolderWatcher(paths: FolderWatcher.launchdFolders()) { [weak self] _ in
                    Task { @MainActor in await self?.rescanPersistence() }
                }
                watcher.start()
                folderWatcher = watcher
                persistenceLoop = Task { [weak self] in
                    while !Task.isCancelled {
                        // The first scan takes what is there as known.
                        await self?.rescanPersistence()
                        try? await Task.sleep(for: Self.persistenceInterval)
                    }
                }
            }
        } else {
            folderWatcher?.stop()
            folderWatcher = nil
            persistenceLoop?.cancel()
            persistenceLoop = nil
        }

        if notifier.isEnabled(.keyboardTaps) {
            if tapsLoop == nil {
                tapsLoop = Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.checkTaps()
                        try? await Task.sleep(for: Self.tapsInterval)
                    }
                }
            }
        } else {
            tapsLoop?.cancel()
            tapsLoop = nil
        }

        monitor.onAppsWithConnections = notifier.isEnabled(.newApps)
            ? { [weak self] apps in self?.appsWithConnections(apps) }
            : nil
    }

    // MARK: - Camera and microphone

    private func captureEvents(_ events: [CaptureEvent]) {
        guard let notifier, notifier.isEnabled(.captureDevices) else { return }
        for event in events {
            let apps = event.apps.map(\.displayName)
            let device = event.kind.label
            switch event.change {
            case .turnedOn:
                let who = apps.isEmpty ? "App not known yet." : "Used by \(Display.list(apps))."
                notifier.post(.captureDevices, title: "\(device) turned on",
                              body: [event.deviceName, who].compactMap { $0 }.joined(separator: " · "),
                              key: "\(event.kind.rawValue):\(event.deviceID ?? "")", quietPeriod: 30)
            case .appStarted:
                guard !apps.isEmpty else { continue }
                notifier.post(.captureDevices, title: "\(Display.list(apps)) started using the \(device.lowercased())",
                              body: event.deviceName ?? "", key: "\(event.kind.rawValue):\(apps.joined())", quietPeriod: 30)
            case .alreadyOn, .turnedOff, .appStopped:
                continue
            }
        }
    }

    // MARK: - Persistence

    private func rescanPersistence() async {
        guard let security, notifier?.isEnabled(.persistence) == true else { return }
        // A scan the user started is under way: wait for it, then scan again for this change.
        while security.isScanningPersistence {
            try? await Task.sleep(for: .seconds(1))
        }
        await security.scanPersistence()
    }

    private func newPersistenceItems(_ items: [PersistenceItem]) {
        guard let notifier, let security else { return }
        let shown = items.prefix(3)
        for item in shown {
            let path = SecurityController.codePath(of: item)
            let signature = path.flatMap { security.signature(of: $0) }?.trustLevel.label
            let body = [path ?? item.configurationPath, signature].compactMap { $0 }.joined(separator: " · ")
            notifier.post(.persistence, title: "New \(Self.singular(item.category)): \(item.label)",
                          body: body, key: item.id, quietPeriod: 3600)
        }
        if items.count > shown.count {
            notifier.post(.persistence, title: "\(items.count - shown.count) more new items start by themselves",
                          body: "See Persistence.", key: "more", quietPeriod: 60)
        }
    }

    static func singular(_ category: PersistenceItem.Category) -> String {
        switch category {
        case .launchAgent: "launch agent"
        case .launchDaemon: "launch daemon"
        case .loginItem: "login item"
        case .backgroundTask: "background task"
        case .cronJob: "cron job"
        case .periodicScript: "periodic script"
        case .systemExtension: "system extension"
        case .kernelExtension: "kernel extension"
        case .configurationProfile: "configuration profile"
        case .browserExtension: "browser extension"
        case .other: "item"
        }
    }

    // MARK: - Keyboard taps

    private func checkTaps() async {
        guard let notifier, notifier.isEnabled(.keyboardTaps) else { return }
        let taps = await Task.detached(priority: .utility) { (try? KeyboardTaps.list()) ?? nil }.value
        guard let taps else { return }
        // Active taps can change or swallow keystrokes; one key per program, not per tap.
        let active = taps.filter { $0.isActive && $0.isEnabled }
        var byKey: [String: KeyboardTap] = [:]
        for tap in active { byKey[tap.tapping.executablePath ?? tap.tapping.name] = tap }
        let fresh = knownTaps.admit(active.map { $0.tapping.executablePath ?? $0.tapping.name }, group: "active")
        if !fresh.isEmpty || !tapsSaved {
            knownTapsFile.save(knownTaps)
            tapsSaved = true
        }
        for key in fresh {
            guard let tap = byKey[key] else { continue }
            let scope = tap.isSystemWide ? "every app's keystrokes" : "the keystrokes of \(tap.tapped?.displayName ?? "one app")"
            notifier.post(.keyboardTaps, title: "\(tap.tapping.displayName) is reading keystrokes",
                          body: "An active keyboard tap: it receives \(scope) and can change them.", key: key, quietPeriod: 3600)
        }
    }

    // MARK: - New apps

    private func appsWithConnections(_ apps: [AppGroup]) {
        guard let notifier, let monitor else { return }
        // Through the helper, every user's processes show up at once: they are their own group,
        // taken as known the first time, instead of all looking new.
        let group = monitor.seesAllProcesses ? "with-helper" : "own"
        let fresh = Set(knownApps.admit(apps.map(\.id), group: group))
        // The first snapshot of a launch may be the baseline: save it too.
        if !fresh.isEmpty || knownAppsSavedAt == .distantPast { knownAppsChanged = true }
        if knownAppsChanged, Date().timeIntervalSince(knownAppsSavedAt) > 30 {
            knownAppsFile.save(knownApps)
            knownAppsSavedAt = Date()
            knownAppsChanged = false
        }
        let newApps = apps.filter { fresh.contains($0.id) }
        guard !newApps.isEmpty else { return }
        if newApps.count > 3 {
            notifier.post(.newApps, title: "\(newApps.count) apps connected for the first time",
                          body: Display.list(newApps.prefix(4).map(\.name)), key: "many", quietPeriod: 60)
            return
        }
        for app in newApps {
            let destination = app.sortedDestinations.first
            var body = destination.map { "To \($0.key.address.description)" } ?? ""
            if let country = destination?.country { body += " (\(country))" }
            if let path = app.bundlePath ?? app.executablePath { body += body.isEmpty ? path : " · \(path)" }
            notifier.post(.newApps, title: "\(app.name) connected for the first time", body: body, key: app.id, quietPeriod: 3600)
        }
    }
}
