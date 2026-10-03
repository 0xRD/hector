import CoreGraphics
import Foundation
import Testing
@testable import HectorCore

@Suite struct KeyboardTapTests {
    private func bit(_ type: CGEventType) -> UInt64 { UInt64(1) << UInt64(type.rawValue) }

    private func record(_ id: UInt32, mask: UInt64, tapping: Int32 = 500, tapped: Int32 = 0,
                        options: UInt32 = 1, location: UInt32 = 1, enabled: Bool = true) -> EventTapRecord {
        EventTapRecord(tapID: id, location: location, options: options, eventsOfInterest: mask,
                       tappingPID: tapping, tappedPID: tapped, isEnabled: enabled)
    }

    private func names(_ pid: Int32) -> ProcessIdentity {
        switch pid {
        case 500: ProcessIdentity(pid: 500, name: "keylogger", executablePath: "/tmp/keylogger")
        case 600: ProcessIdentity(pid: 600, name: "Helper", executablePath: "/Applications/Alpha.app/Contents/MacOS/Helper",
                                  appBundlePath: "/Applications/Alpha.app", appName: "Alpha")
        default: ProcessIdentity(pid: pid, name: "pid \(pid)")
        }
    }

    @Test func keyEventTypesMatchCoreGraphics() {
        #expect(KeyEventKind.keyDown.eventType == CGEventType.keyDown.rawValue)
        #expect(KeyEventKind.keyUp.eventType == CGEventType.keyUp.rawValue)
        #expect(KeyEventKind.flagsChanged.eventType == CGEventType.flagsChanged.rawValue)
        #expect(EventTapLocation(raw: CGEventTapLocation.cghidEventTap.rawValue) == .hid)
        #expect(EventTapLocation(raw: CGEventTapLocation.cgSessionEventTap.rawValue) == .session)
        #expect(EventTapLocation(raw: CGEventTapLocation.cgAnnotatedSessionEventTap.rawValue) == .annotatedSession)
        #expect(CGEventTapOptions.defaultTap.rawValue == 0)
        #expect(CGEventTapOptions.listenOnly.rawValue == 1)
    }

    @Test func readsKeyboardEventsFromTheMask() {
        #expect(KeyboardTaps.keyEvents(in: 0).isEmpty)
        #expect(KeyboardTaps.keyEvents(in: bit(.leftMouseDown) | bit(.mouseMoved)).isEmpty)
        #expect(KeyboardTaps.keyEvents(in: bit(.keyUp) | bit(.keyDown)) == [.keyDown, .keyUp])
        #expect(KeyboardTaps.keyEvents(in: bit(.flagsChanged)) == [.flagsChanged])
        #expect(KeyboardTaps.keyEvents(in: KeyboardTaps.allEventsMask) == KeyEventKind.allCases)
    }

    @Test func keepsOnlyTapsThatSeeTheKeyboard() {
        let records = [
            record(1, mask: bit(.mouseMoved) | bit(.scrollWheel), tapping: 600),
            record(2, mask: bit(.keyDown), tapping: 500),
            record(3, mask: bit(.flagsChanged), tapping: 600, tapped: 500, options: 0),
            record(4, mask: KeyboardTaps.allEventsMask, tapping: 777, enabled: false),
        ]
        let taps = KeyboardTaps.keyboardTaps(from: records, resolve: names)
        #expect(taps.map(\.tapID) == [3, 2, 4])

        let alpha = taps[0]
        #expect(alpha.tapping.displayName == "Alpha")
        #expect(alpha.isActive)
        #expect(!alpha.isSystemWide)
        #expect(alpha.tapped?.name == "keylogger")
        #expect(alpha.keyEvents == [.flagsChanged])

        let logger = taps[1]
        #expect(logger.isSystemWide)
        #expect(logger.tapped == nil)
        #expect(!logger.isActive)
        #expect(logger.location == .session)
        #expect(!logger.allEvents)

        let everything = taps[2]
        #expect(everything.allEvents)
        #expect(!everything.isEnabled)
        #expect(everything.tapping.name == "pid 777")
    }

    @Test func resolvesEachProcessOnce() {
        var calls: [Int32] = []
        let records = [record(1, mask: bit(.keyDown)), record(2, mask: bit(.keyUp)), record(3, mask: bit(.keyDown), tapped: 600)]
        _ = KeyboardTaps.keyboardTaps(from: records) { pid in
            calls.append(pid)
            return ProcessIdentity(pid: pid, name: "p\(pid)")
        }
        #expect(calls.sorted() == [500, 600])
    }

    @Test func readsTheSystemListWithoutPrivileges() {
        // Whatever is installed on the machine. A CI runner may have no window server session, in
        // which case the call fails cleanly rather than crashing.
        guard let records = try? KeyboardTaps.systemRecords() else { return }
        #expect(records.allSatisfy { $0.tappingPID >= 0 })
    }
}

@Suite struct CaptureActivityTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let zoom = ProcessIdentity(pid: 300, name: "zoom.us", appName: "Zoom")
    private let notes = ProcessIdentity(pid: 400, name: "VoiceMemos", appName: "Voice Memos")

    private func camera(_ on: Bool) -> CaptureDevice {
        CaptureDevice(id: "camera:built-in", kind: .camera, name: "FaceTime HD Camera", isInUse: on)
    }

    private func microphone(_ on: Bool, id: String = "microphone:built-in") -> CaptureDevice {
        CaptureDevice(id: id, kind: .microphone, name: "MacBook Pro Microphone", isInUse: on)
    }

    private func snapshot(_ seconds: TimeInterval, _ devices: [CaptureDevice], users: [ProcessIdentity]? = []) -> CaptureSnapshot {
        CaptureSnapshot(takenAt: start.addingTimeInterval(seconds), devices: devices, microphoneUsers: users)
    }

    @Test func headsetsNeedARecordingProcess() {
        #expect(!CaptureActivity.microphoneInUse(isRunningSomewhere: false, hasOutput: false, anyProcessRecording: true))
        #expect(CaptureActivity.microphoneInUse(isRunningSomewhere: true, hasOutput: false, anyProcessRecording: false))
        // A headset playing music: running, but nobody records.
        #expect(!CaptureActivity.microphoneInUse(isRunningSomewhere: true, hasOutput: true, anyProcessRecording: false))
        #expect(CaptureActivity.microphoneInUse(isRunningSomewhere: true, hasOutput: true, anyProcessRecording: true))
        // Unknown: trust the device flag.
        #expect(CaptureActivity.microphoneInUse(isRunningSomewhere: true, hasOutput: true, anyProcessRecording: nil))
    }

    @Test func reportsWhatIsAlreadyOnAtStart() {
        var tracker = CaptureActivityTracker()
        let events = tracker.update(with: snapshot(0, [camera(true), microphone(false)]))
        #expect(events.map(\.change) == [.alreadyOn])
        #expect(events.first?.summary == "FaceTime HD Camera was already on")
        #expect(events.first?.apps.isEmpty == true)
        #expect(tracker.update(with: snapshot(1, [camera(true), microphone(false)])).isEmpty)
    }

    @Test func logsOnAndOffWithTheRecordingApp() {
        var tracker = CaptureActivityTracker()
        #expect(tracker.update(with: snapshot(0, [camera(false), microphone(false)])).isEmpty)

        let on = tracker.update(with: snapshot(1, [camera(true), microphone(true)], users: [zoom]))
        #expect(on.map(\.change) == [.turnedOn, .turnedOn])
        #expect(on.map(\.kind) == [.camera, .microphone])
        #expect(on[0].apps.isEmpty)
        #expect(on[1].apps == [zoom])
        #expect(on[1].date == start.addingTimeInterval(1))
        #expect(on[1].isOn)

        // Another app joins while the microphone stays on, then leaves.
        let joined = tracker.update(with: snapshot(2, [camera(true), microphone(true)], users: [zoom, notes]))
        #expect(joined.map(\.change) == [.appStarted])
        #expect(joined.first?.summary == "Voice Memos started using the microphone")
        let left = tracker.update(with: snapshot(3, [camera(true), microphone(true)], users: [zoom]))
        #expect(left.map(\.change) == [.appStopped])
        #expect(left.first?.apps == [notes])

        // Off: the app that was recording is named once, on the device line.
        let off = tracker.update(with: snapshot(4, [camera(false), microphone(false)], users: []))
        #expect(off.map(\.change) == [.turnedOff, .turnedOff])
        #expect(off[1].apps == [zoom])
        #expect(!off[1].isOn)
        #expect(off[0].summary == "FaceTime HD Camera turned off")
    }

    @Test func lateAttributionBecomesAnAppEvent() {
        var tracker = CaptureActivityTracker()
        _ = tracker.update(with: snapshot(0, [microphone(false)]))
        let on = tracker.update(with: snapshot(1, [microphone(true)], users: []))
        #expect(on.map(\.change) == [.turnedOn])
        #expect(on.first?.apps.isEmpty == true)
        let attributed = tracker.update(with: snapshot(2, [microphone(true)], users: [zoom]))
        #expect(attributed.map(\.change) == [.appStarted])
        #expect(attributed.first?.apps == [zoom])
    }

    @Test func unpluggedWhileInUseTurnsOff() {
        var tracker = CaptureActivityTracker()
        _ = tracker.update(with: snapshot(0, [camera(false), microphone(true, id: "microphone:usb")], users: [zoom]))
        let events = tracker.update(with: snapshot(1, [camera(false)], users: []))
        #expect(events.map(\.change) == [.turnedOff])
        #expect(events.first?.deviceID == "microphone:usb")
        #expect(events.first?.apps == [zoom])
    }

    @Test func unknownUsersAreNotReportedAsStopped() {
        var tracker = CaptureActivityTracker()
        _ = tracker.update(with: snapshot(0, [microphone(true)], users: [zoom]))
        #expect(tracker.update(with: snapshot(1, [microphone(true)], users: nil)).isEmpty)
        #expect(tracker.microphoneUsers[zoom.pid] == zoom)
    }

    @Test func appsAlreadyRecordingAtStartAreReportedOnce() {
        var tracker = CaptureActivityTracker()
        // Started with the microphone on: the app is named on the device line, not twice.
        let events = tracker.update(with: snapshot(0, [microphone(true)], users: [zoom]))
        #expect(events.map(\.change) == [.alreadyOn])
        #expect(events.first?.apps == [zoom])
    }

    @Test func readsDevicesWithoutOpeningThem() {
        // Property reads only: must not crash or prompt, whatever hardware the machine has.
        let snapshot = CaptureDeviceReader.snapshot()
        #expect(Set(snapshot.devices.map(\.id)).count == snapshot.devices.count)
    }
}

@Suite struct SensorIndicatorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let booth = ProcessIdentity(pid: 640, name: "Photo Booth", appName: "Photo Booth", bundleIdentifier: "com.apple.PhotoBooth")
    private let zoom = ProcessIdentity(pid: 700, name: "zoom.us", appName: "zoom.us", bundleIdentifier: "us.zoom.xos")

    private func camera(_ on: Bool) -> CaptureDevice {
        CaptureDevice(id: "camera:built-in", kind: .camera, name: "FaceTime HD Camera", isInUse: on)
    }

    private func snapshot(_ seconds: TimeInterval, on: Bool, cameraUsers: [ProcessIdentity]?) -> CaptureSnapshot {
        CaptureSnapshot(takenAt: start.addingTimeInterval(seconds), devices: [camera(on)], microphoneUsers: [], cameraUsers: cameraUsers)
    }

    private func line(_ message: String, path: String = SensorIndicatorLog.controlCenterPath) -> Substring {
        let object: [String: Any] = ["processImagePath": path, "eventMessage": message, "subsystem": "com.apple.controlcenter"]
        return Substring(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    @Test func parsesCameraAndMicrophoneAttributions() {
        let parsed = SensorIndicatorLog.attributions(
            fromMessage: #"Active activity attributions changed to ["loc:com.apple.reminders", "cam:com.apple.PhotoBooth", "mic:us.zoom.xos"]"#)
        #expect(parsed?[.camera] == ["com.apple.PhotoBooth"])
        #expect(parsed?[.microphone] == ["us.zoom.xos"])
        let empty = SensorIndicatorLog.attributions(fromMessage: "Active activity attributions changed to []")
        #expect(empty?[.camera] == [])
        #expect(SensorIndicatorLog.attributions(fromMessage: #"Recent activity attributions changed to ["cam:x"]"#) == nil)
    }

    @Test func dropsMalformedIdentifiers() {
        let parsed = SensorIndicatorLog.attributions(
            fromMessage: #"Active activity attributions changed to ["cam:../../evil", "cam:", "cam:a b", "cam:-x", "cam:com.ok.App"]"#)
        #expect(parsed?[.camera] == ["com.ok.App"])
    }

    @Test func trustsOnlyControlCenterItself() {
        let message = #"Active activity attributions changed to ["cam:com.apple.PhotoBooth"]"#
        #expect(SensorIndicatorLog.attributions(fromLogLine: line(message))?[.camera] == ["com.apple.PhotoBooth"])
        // Any process can log under Control Center's subsystem; the sender's path cannot be faked.
        #expect(SensorIndicatorLog.attributions(fromLogLine: line(message, path: "/tmp/spoofer")) == nil)
        #expect(SensorIndicatorLog.attributions(fromLogLine: "Filtering the log data using …") == nil)
    }

    @Test func namesTheCameraAppOnTheDeviceLine() {
        var tracker = CaptureActivityTracker()
        _ = tracker.update(with: snapshot(0, on: false, cameraUsers: []))
        let on = tracker.update(with: snapshot(1, on: true, cameraUsers: [booth]))
        #expect(on.map(\.change) == [.turnedOn])
        #expect(on.first?.apps == [booth])
        let off = tracker.update(with: snapshot(2, on: false, cameraUsers: [booth]))
        #expect(off.map(\.change) == [.turnedOff])
        #expect(off.first?.apps == [booth])
        // The indicator lagging behind the camera adds no "stopped" line.
        #expect(tracker.update(with: snapshot(3, on: false, cameraUsers: [])).isEmpty)
    }

    @Test func lateOrChangingCameraAttributionBecomesAppEvents() {
        var tracker = CaptureActivityTracker()
        _ = tracker.update(with: snapshot(0, on: false, cameraUsers: nil))
        let on = tracker.update(with: snapshot(1, on: true, cameraUsers: nil))
        #expect(on.first?.apps.isEmpty == true)
        let named = tracker.update(with: snapshot(2, on: true, cameraUsers: [booth]))
        #expect(named.map(\.change) == [.appStarted])
        #expect(named.first?.summary == "Photo Booth started using the camera")
        let swapped = tracker.update(with: snapshot(3, on: true, cameraUsers: [zoom]))
        #expect(swapped.map(\.change) == [.appStarted, .appStopped])
    }
}
