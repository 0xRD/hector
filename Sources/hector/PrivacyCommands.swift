import Darwin
import Foundation
import HectorCore

/// `hector taps [--json]`
func taps(_ args: Arguments) throws {
    let taps = try KeyboardTaps.list()
    if args.flags.contains("--json") {
        print(String(decoding: try JSONEncoder.hector.encode(taps), as: UTF8.self))
        return
    }
    guard !taps.isEmpty else {
        print("No event tap receives keystrokes.")
        return
    }
    print(pad("TAP", 11) + pad("PID", 7) + pad("MODE", 13) + pad("SCOPE", 22) + pad("SIGNATURE", 22) + "PROCESS")
    var signatures: [String: String] = [:]
    for tap in taps {
        let process = tap.tapping
        let scope = tap.isSystemWide ? "all apps" : "only \(tap.tapped?.displayName ?? "pid") (\(tap.tappedPID))"
        var mode = tap.isActive ? "active" : "listen-only"
        if !tap.isEnabled { mode += ", off" }
        var trust = "-"
        if let path = process.appBundlePath ?? process.executablePath {
            if let known = signatures[path] {
                trust = known
            } else {
                trust = (try? CodeSignature.analyze(URL(fileURLWithPath: path)))?.trustLevel.rawValue ?? "unreadable"
                signatures[path] = trust
            }
        }
        let name = process.displayName + (process.executablePath.map { "  \($0)" } ?? "")
        print(pad(String(tap.tapID), 11) + pad(String(process.pid), 7) + pad(mode, 13) + pad(LogText.sanitized(scope), 22)
              + pad(trust, 22) + LogText.sanitized(name))
        let events = tap.allEvents ? "every event" : tap.keyEvents.map { $0.label.lowercased() }.joined(separator: ", ")
        print(String(repeating: " ", count: 18) + "\(events) · \(tap.location.label.lowercased())")
    }
    let active = taps.filter { $0.isActive && $0.isEnabled }.count
    let off = taps.filter { !$0.isEnabled }.count
    print("\(taps.count) keyboard taps, \(active) active (can change or drop keystrokes)" + (off > 0 ? ", \(off) switched off." : "."))
}

/// `hector devices [--json] [--watch]`
@MainActor
func devices(_ args: Arguments) async throws {
    let json = args.flags.contains("--json")
    guard args.flags.contains("--watch") else {
        var snapshot = CaptureDeviceReader.snapshot()
        if !snapshot.camerasInUse.isEmpty, let latest = SensorIndicatorLog.latest() {
            snapshot.cameraUsers = SensorIndicatorLog.processes(forBundleIdentifiers: latest[.camera] ?? [])
        }
        if json {
            print(String(decoding: try JSONEncoder.hector.encode(snapshot), as: UTF8.self))
        } else {
            printDevices(snapshot)
        }
        return
    }

    let encoder = JSONEncoder.hectorWire
    let monitor = CaptureDeviceMonitor { _, events in
        for event in events {
            if json {
                if let data = try? encoder.encode(event) { emit(String(decoding: data, as: UTF8.self)) }
            } else {
                emit(eventLine(event))
            }
        }
    }
    if !json { emit("Watching cameras and microphones. Press Ctrl-C to stop.") }
    monitor.start()
    // Runs until interrupted; the listeners go away with the process. Referencing the monitor in
    // the loop also keeps it alive.
    while monitor.isRunning {
        try await Task.sleep(for: .seconds(3600))
    }
}

/// Unbuffered, so each event shows at once even when the output is piped.
private func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private func printDevices(_ snapshot: CaptureSnapshot) {
    for kind in CaptureDeviceKind.allCases {
        let devices = snapshot.devices.filter { $0.kind == kind }
        print(kind == .camera ? "Cameras" : "Audio inputs")
        if devices.isEmpty { print("  none") }
        for device in devices {
            var state = device.isInUse ? "IN USE" : "off"
            if device.kind == .microphone && device.isRunningSomewhere && !device.isInUse { state = "playing only" }
            print("  " + pad(state, 14) + LogText.sanitized(device.name))
        }
    }
    if let users = snapshot.microphoneUsers {
        let names = users.map { "\($0.displayName) (\($0.pid))" }
        print("Recording audio: " + (names.isEmpty ? "nobody" : LogText.sanitized(names.joined(separator: ", "))))
    } else {
        print("Recording audio: unknown (Core Audio did not list its client processes)")
    }
    if snapshot.camerasInUse.isEmpty { return }
    // The indicator's last change in the past ten minutes, from Control Center's log.
    if let users = snapshot.cameraUsers {
        let names = users.map { "\($0.displayName) (\($0.pid))" }
        print("Using a camera: " + (names.isEmpty ? "no app reported" : LogText.sanitized(names.joined(separator: ", "))))
    } else {
        print("Using a camera: unknown (Control Center logged no indicator change in the last ten minutes)")
    }
}

private func eventLine(_ event: CaptureEvent) -> String {
    let time = event.date.formatted(date: .omitted, time: .standard)
    var line = "\(time)  \(event.isOn ? "ON " : "OFF")  \(event.summary)"
    if event.deviceID != nil, !event.apps.isEmpty {
        line += " · " + event.apps.map { "\($0.displayName) (\($0.pid))" }.joined(separator: ", ")
    }
    return LogText.sanitized(line)
}
