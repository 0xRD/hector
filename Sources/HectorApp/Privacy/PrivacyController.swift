import Foundation
import HectorCore
import Observation

/// Keyboard taps and the camera and microphone log, with the selection of their screens.
@MainActor
@Observable
final class PrivacyController {
    // MARK: Keyboard taps

    private(set) var taps: [KeyboardTap]?
    private(set) var tapsError: String?
    private(set) var isLoadingTaps = false
    private(set) var tapsLoadedAt: Date?
    var selectedTap: KeyboardTap.ID?

    // MARK: Camera and microphone

    /// Every camera and audio input, from the last read.
    private(set) var devices: [CaptureDevice] = []
    /// Processes recording audio now; `nil` when Core Audio did not say.
    private(set) var microphoneUsers: [ProcessIdentity]?
    /// From Control Center's indicator log; `nil` when unknown.
    private(set) var cameraUsers: [ProcessIdentity]?
    /// Newest first, at most `maximumEvents`.
    private(set) var events: [CaptureEvent] = []
    private(set) var isMonitoring = false
    private(set) var monitoringSince: Date?

    static let maximumEvents = 500

    @ObservationIgnored private var monitor: CaptureDeviceMonitor?

    // MARK: - Keyboard taps

    func refreshTaps() async {
        guard !isLoadingTaps else { return }
        isLoadingTaps = true
        defer { isLoadingTaps = false }
        let result: Result<[KeyboardTap], Error> = await Task.detached(priority: .userInitiated) {
            Result { try KeyboardTaps.list() }
        }.value
        switch result {
        case .success(let list):
            taps = list
            tapsError = nil
        case .failure(let error):
            tapsError = String(describing: error)
        }
        tapsLoadedAt = Date()
        if let selected = selectedTap, taps?.contains(where: { $0.id == selected }) != true { selectedTap = nil }
    }

    /// The code to analyze for a tap: the app bundle when there is one, else the executable.
    static func codePath(of process: ProcessIdentity) -> String? {
        process.appBundlePath ?? process.executablePath
    }

    // MARK: - Camera and microphone

    var devicesInUse: [CaptureDevice] { devices.filter(\.isInUse) }

    /// Starts listening to the cameras and microphones. Cheap: listeners plus a read every 2 s.
    func startMonitoring() {
        guard monitor == nil else { return }
        let monitor = CaptureDeviceMonitor { [weak self] snapshot, events in
            self?.apply(snapshot, events)
        }
        self.monitor = monitor
        isMonitoring = true
        monitoringSince = Date()
        monitor.start()
    }

    /// Removes every listener. The log is kept.
    func stopMonitoring() {
        monitor?.stop()
        monitor = nil
        isMonitoring = false
        monitoringSince = nil
    }

    func clearLog() {
        events = []
    }

    private func apply(_ snapshot: CaptureSnapshot, _ newEvents: [CaptureEvent]) {
        // Read every 2 s: assign only what changed, so the screens do not redraw for nothing.
        if devices != snapshot.devices { devices = snapshot.devices }
        if microphoneUsers != snapshot.microphoneUsers { microphoneUsers = snapshot.microphoneUsers }
        if cameraUsers != snapshot.cameraUsers { cameraUsers = snapshot.cameraUsers }
        guard !newEvents.isEmpty else { return }
        events.insert(contentsOf: newEvents.reversed(), at: 0)
        if events.count > Self.maximumEvents { events.removeLast(events.count - Self.maximumEvents) }
    }
}
