import Foundation

/// Camera or microphone.
public enum CaptureDeviceKind: String, Codable, CaseIterable, Sendable {
    case camera
    case microphone

    public var label: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        }
    }
}

/// A camera or an audio input device, and whether something records from it now.
public struct CaptureDevice: Codable, Hashable, Identifiable, Sendable {
    /// Kind and the system's unique ID of the device, stable across reconnections.
    public var id: String
    public var kind: CaptureDeviceKind
    public var name: String
    /// What Hector concludes; see `CaptureActivity.microphoneInUse` for microphones.
    public var isInUse: Bool
    /// The raw "running somewhere" flag of the device: some process does I/O on it.
    public var isRunningSomewhere: Bool
    /// An audio device that also plays sound (a USB or Bluetooth headset): its "running" flag is
    /// also set by playback alone.
    public var hasOutput: Bool

    public init(id: String, kind: CaptureDeviceKind, name: String, isInUse: Bool,
                isRunningSomewhere: Bool? = nil, hasOutput: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isInUse = isInUse
        self.isRunningSomewhere = isRunningSomewhere ?? isInUse
        self.hasOutput = hasOutput
    }
}

/// What the cameras and microphones are doing at one moment.
public struct CaptureSnapshot: Codable, Sendable {
    public var takenAt: Date
    public var devices: [CaptureDevice]
    /// Processes recording audio input right now, from the Core Audio process objects. `nil` when
    /// the system did not answer, so which app uses the microphone is unknown.
    public var microphoneUsers: [ProcessIdentity]?

    public init(takenAt: Date, devices: [CaptureDevice], microphoneUsers: [ProcessIdentity]?) {
        self.takenAt = takenAt
        self.devices = devices
        self.microphoneUsers = microphoneUsers
    }

    public var camerasInUse: [CaptureDevice] { devices.filter { $0.kind == .camera && $0.isInUse } }
    public var microphonesInUse: [CaptureDevice] { devices.filter { $0.kind == .microphone && $0.isInUse } }
}

/// One line of the camera and microphone log.
public struct CaptureEvent: Codable, Hashable, Identifiable, Sendable {
    public enum Change: String, Codable, Sendable {
        /// Already in use when monitoring started.
        case alreadyOn
        case turnedOn
        /// Stopped, or disconnected while in use.
        case turnedOff
        /// An app started recording from a microphone that was already on.
        case appStarted
        /// An app stopped recording while a microphone stayed on.
        case appStopped
    }

    public var id: UUID
    public var date: Date
    public var change: Change
    public var kind: CaptureDeviceKind
    /// `nil` for app events, which are not tied to one device.
    public var deviceID: String?
    public var deviceName: String?
    /// The apps known to use the device; empty when unknown (always for cameras).
    public var apps: [ProcessIdentity]

    public init(id: UUID = UUID(), date: Date, change: Change, kind: CaptureDeviceKind,
                deviceID: String?, deviceName: String?, apps: [ProcessIdentity]) {
        self.id = id
        self.date = date
        self.change = change
        self.kind = kind
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.apps = apps
    }

    /// Whether the event leaves the device (or the app) on.
    public var isOn: Bool {
        switch change {
        case .alreadyOn, .turnedOn, .appStarted: true
        case .turnedOff, .appStopped: false
        }
    }

    /// One sentence, such as "FaceTime HD Camera turned on" or "Zoom started using the microphone".
    public var summary: String {
        let device = deviceName ?? kind.label
        let appNames = apps.map(\.displayName)
        let app = appNames.isEmpty ? "An app" : ListFormatter.localizedString(byJoining: appNames)
        let noun = kind.label.lowercased()
        switch change {
        case .alreadyOn: return deviceName == nil ? "\(app) was already using the \(noun)" : "\(device) was already on"
        case .turnedOn: return "\(device) turned on"
        case .turnedOff: return "\(device) turned off"
        case .appStarted: return "\(app) started using the \(noun)"
        case .appStopped: return "\(app) stopped using the \(noun)"
        }
    }
}

/// Pure rules behind the camera and microphone monitor, kept apart from Core Audio so they can be
/// tested.
public enum CaptureActivity {
    /// Whether an audio input device is recording.
    ///
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` says some process does I/O on the device. For
    /// an input-only device (the built-in microphone) that means recording. A headset is one
    /// device for both directions, so music playback alone sets the flag: for those, trust it only
    /// when some process records (`anyProcessRecording`), when that is known.
    public static func microphoneInUse(isRunningSomewhere: Bool, hasOutput: Bool, anyProcessRecording: Bool?) -> Bool {
        guard isRunningSomewhere else { return false }
        guard hasOutput, let anyProcessRecording else { return true }
        return anyProcessRecording
    }
}

/// Turns successive snapshots into log events: devices that turn on or off, and apps that start or
/// stop recording from the microphone while it stays on.
public struct CaptureActivityTracker: Sendable {
    public private(set) var devices: [String: CaptureDevice] = [:]
    public private(set) var microphoneUsers: [Int32: ProcessIdentity] = [:]
    private var hasStarted = false

    public init() {}

    /// The events between the previous snapshot and this one. The first call reports what is
    /// already on as `alreadyOn`.
    public mutating func update(with snapshot: CaptureSnapshot) -> [CaptureEvent] {
        let date = snapshot.takenAt
        let users: [ProcessIdentity] = (snapshot.microphoneUsers ?? []).sorted { $0.pid < $1.pid }
        let previousUsers: [ProcessIdentity] = microphoneUsers.values.sorted { $0.pid < $1.pid }
        var current: [String: CaptureDevice] = [:]
        for device in snapshot.devices where current[device.id] == nil { current[device.id] = device }

        var events: [CaptureEvent] = []
        // PIDs already named by a device event, so they do not get a second, app-level line.
        var reported = Set<Int32>()

        for device in current.values.sorted(by: { $0.id < $1.id }) {
            let wasOn = devices[device.id]?.isInUse ?? false
            let isMicrophone = device.kind == .microphone
            if device.isInUse && !wasOn {
                let apps = isMicrophone ? users : []
                events.append(CaptureEvent(date: date, change: hasStarted ? .turnedOn : .alreadyOn, kind: device.kind,
                                           deviceID: device.id, deviceName: device.name, apps: apps))
                reported.formUnion(apps.map(\.pid))
            } else if !device.isInUse && wasOn {
                let apps = isMicrophone ? previousUsers : []
                events.append(CaptureEvent(date: date, change: .turnedOff, kind: device.kind,
                                           deviceID: device.id, deviceName: device.name, apps: apps))
                reported.formUnion(apps.map(\.pid))
            }
        }
        // Unplugged while in use.
        for old in devices.values.sorted(by: { $0.id < $1.id }) where current[old.id] == nil && old.isInUse {
            let apps = old.kind == .microphone ? previousUsers : []
            events.append(CaptureEvent(date: date, change: .turnedOff, kind: old.kind,
                                       deviceID: old.id, deviceName: old.name, apps: apps))
            reported.formUnion(apps.map(\.pid))
        }

        // Unknown this time: keep the previous users rather than reporting them all as stopped.
        if snapshot.microphoneUsers != nil {
            var next: [Int32: ProcessIdentity] = [:]
            for user in users where next[user.pid] == nil { next[user.pid] = user }
            for user in users where microphoneUsers[user.pid] == nil && !reported.contains(user.pid) {
                events.append(CaptureEvent(date: date, change: hasStarted ? .appStarted : .alreadyOn, kind: .microphone,
                                           deviceID: nil, deviceName: nil, apps: [user]))
            }
            for user in previousUsers where next[user.pid] == nil && !reported.contains(user.pid) {
                events.append(CaptureEvent(date: date, change: .appStopped, kind: .microphone,
                                           deviceID: nil, deviceName: nil, apps: [user]))
            }
            microphoneUsers = next
        }

        devices = current
        hasStarted = true
        return events
    }
}
