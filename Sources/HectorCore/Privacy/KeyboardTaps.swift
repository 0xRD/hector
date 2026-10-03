import CoreGraphics
import Foundation

/// One entry of the window server's event tap list, copied out of `CGEventTapInformation` so the
/// rest of the code (and the tests) never touch the C struct.
public struct EventTapRecord: Codable, Hashable, Sendable {
    public var tapID: UInt32
    /// Raw `CGEventTapLocation`: 0 HID, 1 session, 2 annotated session.
    public var location: UInt32
    /// Raw `CGEventTapOptions`: 0 active (can modify or drop events), 1 listen only.
    public var options: UInt32
    /// `CGEventMask`: bit N set when events of `CGEventType` N are delivered to the tap.
    public var eventsOfInterest: UInt64
    public var tappingPID: Int32
    /// 0 when the tap sees the events of every process (a session or HID tap).
    public var tappedPID: Int32
    public var isEnabled: Bool

    public init(tapID: UInt32, location: UInt32, options: UInt32, eventsOfInterest: UInt64,
                tappingPID: Int32, tappedPID: Int32, isEnabled: Bool) {
        self.tapID = tapID
        self.location = location
        self.options = options
        self.eventsOfInterest = eventsOfInterest
        self.tappingPID = tappingPID
        self.tappedPID = tappedPID
        self.isEnabled = isEnabled
    }

    init(_ info: CGEventTapInformation) {
        self.init(tapID: info.eventTapID,
                  location: info.tapPoint.rawValue,
                  options: info.options.rawValue,
                  eventsOfInterest: info.eventsOfInterest,
                  tappingPID: info.tappingProcess,
                  tappedPID: info.processBeingTapped,
                  isEnabled: info.enabled)
    }
}

/// Keyboard event types a tap can ask for.
public enum KeyEventKind: String, Codable, CaseIterable, Comparable, Sendable {
    case keyDown
    case keyUp
    /// Modifier keys (Shift, Command, Option, Control, Caps Lock, Fn).
    case flagsChanged

    /// The `CGEventType` raw value (`kCGEventKeyDown` 10, `kCGEventKeyUp` 11, `kCGEventFlagsChanged` 12).
    public var eventType: UInt32 {
        switch self {
        case .keyDown: 10
        case .keyUp: 11
        case .flagsChanged: 12
        }
    }

    public var label: String {
        switch self {
        case .keyDown: "Key down"
        case .keyUp: "Key up"
        case .flagsChanged: "Modifier keys"
        }
    }

    public static func < (lhs: KeyEventKind, rhs: KeyEventKind) -> Bool { lhs.eventType < rhs.eventType }
}

/// Where in the event stream a tap sits.
public enum EventTapLocation: String, Codable, Sendable {
    /// Where HID events enter the window server: before any session sees them (root, or
    /// Accessibility / Input Monitoring permission).
    case hid
    /// Where events enter a login session.
    case session
    /// Where session events have been annotated for a target application.
    case annotatedSession
    case unknown

    public init(raw: UInt32) {
        switch raw {
        case 0: self = .hid
        case 1: self = .session
        case 2: self = .annotatedSession
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .hid: "HID (hardware)"
        case .session: "Login session"
        case .annotatedSession: "Annotated session"
        case .unknown: "Unknown"
        }
    }
}

/// An event tap that receives keystrokes, in the spirit of Objective-See's ReiKey.
public struct KeyboardTap: Codable, Hashable, Identifiable, Sendable {
    public var tapID: UInt32
    public var location: EventTapLocation
    /// An active tap can change or swallow keystrokes; a listen-only tap can still read them.
    public var isActive: Bool
    public var isEnabled: Bool
    /// The keyboard events the tap asked for, sorted.
    public var keyEvents: [KeyEventKind]
    /// The tap asked for every event type (`kCGEventMaskForAllEvents`), keyboard included.
    public var allEvents: Bool
    /// The process that installed the tap: the one that receives the keystrokes.
    public var tapping: ProcessIdentity
    /// 0 when the tap sees every app's keystrokes.
    public var tappedPID: Int32
    /// The only process whose keystrokes the tap sees, when it is not system-wide.
    public var tapped: ProcessIdentity?

    public var id: UInt32 { tapID }
    public var isSystemWide: Bool { tappedPID == 0 }

    public init(tapID: UInt32, location: EventTapLocation, isActive: Bool, isEnabled: Bool, keyEvents: [KeyEventKind],
                allEvents: Bool, tapping: ProcessIdentity, tappedPID: Int32, tapped: ProcessIdentity?) {
        self.tapID = tapID
        self.location = location
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.keyEvents = keyEvents
        self.allEvents = allEvents
        self.tapping = tapping
        self.tappedPID = tappedPID
        self.tapped = tapped
    }
}

/// Lists the event taps that intercept the keyboard, from the public `CGGetEventTapList`.
///
/// Needs no privilege and no permission: any process may read the list. It shows who installed
/// a tap and what it asked for, not what it does with the keystrokes.
public enum KeyboardTaps {
    public struct ListError: Error, CustomStringConvertible {
        public var code: Int32
        public var description: String { "CGGetEventTapList failed (CGError \(code))." }
    }

    /// `kCGEventMaskForAllEvents`.
    public static let allEventsMask: UInt64 = ~0

    /// The keyboard events in a `CGEventMask`, sorted.
    public static func keyEvents(in mask: UInt64) -> [KeyEventKind] {
        KeyEventKind.allCases.filter { kind in mask & (UInt64(1) << UInt64(kind.eventType)) != 0 }
    }

    public static func isKeyboardTap(_ record: EventTapRecord) -> Bool {
        !keyEvents(in: record.eventsOfInterest).isEmpty
    }

    /// Keeps the records that receive keyboard events and describes them. `resolve` names a PID;
    /// it is injectable so tests need no real process. Sorted by tapping app name, then tap ID.
    public static func keyboardTaps(from records: [EventTapRecord],
                                    resolve: (Int32) -> ProcessIdentity) -> [KeyboardTap] {
        let keyboard = records.filter(isKeyboardTap)
        // Each PID is resolved once, however many taps it owns.
        var names: [Int32: ProcessIdentity] = [:]
        for record in keyboard {
            for pid in [record.tappingPID, record.tappedPID] where pid != 0 && names[pid] == nil {
                names[pid] = resolve(pid)
            }
        }
        let taps = keyboard.map { record -> KeyboardTap in
            let tapping = names[record.tappingPID] ?? ProcessIdentity(pid: record.tappingPID, name: "pid \(record.tappingPID)")
            let tapped: ProcessIdentity? = record.tappedPID == 0 ? nil : names[record.tappedPID]
            return KeyboardTap(tapID: record.tapID,
                               location: EventTapLocation(raw: record.location),
                               isActive: record.options == 0,
                               isEnabled: record.isEnabled,
                               keyEvents: keyEvents(in: record.eventsOfInterest),
                               allEvents: record.eventsOfInterest == allEventsMask,
                               tapping: tapping,
                               tappedPID: record.tappedPID,
                               tapped: tapped)
        }
        return taps.sorted { lhs, rhs in
            let order = lhs.tapping.displayName.localizedCaseInsensitiveCompare(rhs.tapping.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.tapID < rhs.tapID
        }
    }

    /// Every event tap installed in the system right now, keyboard or not.
    public static func systemRecords() throws -> [EventTapRecord] {
        var count: UInt32 = 0
        let sizing = CGGetEventTapList(0, nil, &count)
        guard sizing == .success else { throw ListError(code: sizing.rawValue) }
        guard count > 0 else { return [] }

        // A tap can appear between the two calls: leave some room.
        let capacity: UInt32 = count + 16
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(capacity))
        var filled: UInt32 = 0
        let status: CGError = list.withUnsafeMutableBufferPointer { buffer in
            CGGetEventTapList(capacity, buffer.baseAddress, &filled)
        }
        guard status == .success else { throw ListError(code: status.rawValue) }
        let used = Int(min(filled, capacity))
        return list.prefix(used).map { EventTapRecord($0) }
    }

    /// The keyboard taps installed right now, with their processes named.
    public static func list() throws -> [KeyboardTap] {
        keyboardTaps(from: try systemRecords(), resolve: ProcessIdentity.resolve(pid:))
    }
}
