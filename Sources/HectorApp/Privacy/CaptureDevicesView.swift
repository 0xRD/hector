import HectorCore
import SwiftUI

extension CaptureDeviceKind {
    var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        }
    }

    var offSymbol: String {
        switch self {
        case .camera: "video.slash"
        case .microphone: "mic.slash"
        }
    }
}

/// When the cameras and microphones turn on and off, and which app records audio.
struct CaptureDevicesView: View {
    @Environment(PrivacyController.self) private var privacy

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                if !privacy.isMonitoring {
                    Banner("Monitoring is paused", message: "Hector is not listening to the cameras and microphones. The log below is kept.",
                           kind: .neutral, systemImage: "pause.circle") {
                        Button("Resume") { privacy.startMonitoring() }
                    }
                }
                InUseNowSection()
                CaptureLogSection()
                CaptureLimitsNote()
            }
            .padding(Spacing.xl + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .canvasBackground()
        .task { privacy.startMonitoring() }
    }

    private var header: some View {
        ScreenHeader("Camera & microphone", subtitle: subtitle, systemImage: "web.camera", tint: .hectorInfo) {
            // Keeping watch while monitoring; resting while paused.
            HectorMark(gaze: privacy.isMonitoring ? .ahead : .resting, detailed: true)
                .frame(width: 30, height: 30)
                .help(privacy.isMonitoring ? "Hector is keeping watch" : "Hector is resting: monitoring is paused")
            if privacy.isMonitoring {
                Button {
                    privacy.stopMonitoring()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .help("Stop listening to the devices")
            }
            Button {
                privacy.clearLog()
            } label: {
                Label("Clear Log", systemImage: "trash")
            }
            .disabled(privacy.events.isEmpty)
        }
    }

    private var subtitle: String {
        guard privacy.isMonitoring, let since = privacy.monitoringSince else { return "Paused" }
        let cameras = privacy.devices.filter { $0.kind == .camera }.count
        let inputs = privacy.devices.filter { $0.kind == .microphone }.count
        let time = Display.time(since)
        return "Watching \(cameras) camera\(cameras == 1 ? "" : "s") and \(inputs) audio input\(inputs == 1 ? "" : "s") since \(time)"
    }
}

/// The devices in use right now, with the apps recording audio, then every device in a compact
/// list: the screen opens on what is on, not on a column of "Off".
private struct InUseNowSection: View {
    @Environment(PrivacyController.self) private var privacy

    var body: some View {
        let inUse = privacy.devicesInUse
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader("In use now", subtitle: inUse.isEmpty ? nil : "\(inUse.count) device\(inUse.count == 1 ? "" : "s") on")
            Card {
                if !privacy.isMonitoring {
                    Text("Not monitoring.").font(.callout).foregroundStyle(.secondary)
                } else if inUse.isEmpty {
                    Label("No camera or microphone is in use.", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(inUse) { device in
                        DeviceRow(device: device, users: users(for: device))
                    }
                }
            }
            if !privacy.devices.isEmpty {
                DisclosureGroup("All devices (\(privacy.devices.count))") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(privacy.devices.sorted { ($0.kind == .camera ? 0 : 1, $0.name) < ($1.kind == .camera ? 0 : 1, $1.name) }) { device in
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: device.isInUse ? device.kind.symbol : device.kind.offSymbol)
                                    .foregroundStyle(device.isInUse ? Color.hectorWarning : Color.secondary)
                                    .frame(width: 18)
                                Text(device.name).lineLimit(1)
                                Text(device.kind.label).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if device.isInUse {
                                    StatusPill("In use", kind: .warning, systemImage: "circle.fill", size: .small)
                                }
                            }
                        }
                    }
                    .padding(.top, Spacing.xs)
                }
                .font(.callout)
            }
        }
    }

    private func users(for device: CaptureDevice) -> [ProcessIdentity]? {
        guard device.isInUse else { return [] }
        return device.kind == .camera ? privacy.cameraUsers : privacy.microphoneUsers
    }
}

private struct DeviceRow: View {
    let device: CaptureDevice
    /// `nil` when unknown; empty for devices that are off.
    let users: [ProcessIdentity]?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Image(systemName: device.isInUse ? device.kind.symbol : device.kind.offSymbol)
                .foregroundStyle(device.isInUse ? Color.hectorWarning : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(device.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: Spacing.sm)
            if device.isInUse {
                StatusPill("In use", kind: .warning, systemImage: "circle.fill", size: .small)
            } else {
                StatusPill("Off", kind: .neutral, size: .small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        guard device.isInUse else {
            if device.kind == .microphone && device.isRunningSomewhere { return "Microphone · playing sound only" }
            return device.kind.label
        }
        let kind = device.kind.label
        guard let users else { return "\(kind) · app unknown" }
        if users.isEmpty { return "\(kind) · no app reported yet" }
        return "\(kind) · " + users.map { "\($0.displayName) (\($0.pid))" }.joined(separator: ", ")
    }
}

/// Every change seen since monitoring started, newest first.
private struct CaptureLogSection: View {
    @Environment(PrivacyController.self) private var privacy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader("Log", subtitle: "Kept in memory while Hector runs, up to \(PrivacyController.maximumEvents) events")
            if privacy.events.isEmpty {
                Card {
                    EmptyStateView("All quiet", systemImage: "web.camera",
                                   message: "Nothing has turned on since Hector started listening.", tint: .hectorOK, compact: true,
                                   hector: privacy.isMonitoring ? .ahead : .resting)
                }
            } else {
                Card(spacing: Spacing.sm) {
                    ForEach(privacy.events) { event in
                        CaptureEventRow(event: event)
                    }
                }
            }
        }
    }
}

private struct CaptureEventRow: View {
    let event: CaptureEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Text(Display.time(event.date, seconds: true))
                .font(Font.dataMonoCaption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Image(systemName: event.isOn ? event.kind.symbol : event.kind.offSymbol)
                .foregroundStyle(event.isOn ? Color.hectorWarning : Color.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(event.summary).lineLimit(2)
                if let apps = appsLine { Text(apps).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if let expected = CaptureEventRow.expectedNote(for: event) {
                    Text(expected).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// macOS's own clients that hold the microphone all the time, explained so they do not look
    /// like a recording app.
    static func expectedNote(for event: CaptureEvent) -> String? {
        let known: [String: String] = [
            "corespeechd": "Expected: macOS listening for “Hey Siri” or dictation; nothing is recorded or sent until it hears it.",
            "corespeechd_system": "Expected: macOS listening for “Hey Siri” or dictation; nothing is recorded or sent until it hears it.",
        ]
        guard event.apps.count == 1, let path = event.apps[0].executablePath, path.hasPrefix("/System/") else { return nil }
        return known[event.apps[0].name]
    }

    /// The apps on a device line; app events already name them in the summary.
    private var appsLine: String? {
        guard event.deviceID != nil else { return nil }
        guard !event.apps.isEmpty else { return event.kind == .camera && event.isOn ? "App not known yet" : nil }
        return event.apps.map { "\($0.displayName) (\($0.pid))" }.joined(separator: ", ")
    }
}

/// What this screen can and cannot know, in plain words.
private struct CaptureLimitsNote: View {
    var body: some View {
        Banner("What Hector can see",
               message: "On and off come from the devices themselves, so every app is covered. For the microphone, macOS names the processes that record. For cameras, Hector reads which app macOS puts behind the green indicator, from Control Center's log; it can lag a moment behind the camera. Hector never opens a camera or a microphone.",
               kind: .info, systemImage: "info.circle")
    }
}
