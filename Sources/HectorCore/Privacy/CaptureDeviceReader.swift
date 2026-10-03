import CoreAudio
import CoreMediaIO
import Foundation

/// Reads the state of cameras (CoreMediaIO) and audio input devices (Core Audio).
///
/// Only properties are read: no device is opened, so no camera or microphone permission is asked
/// and the green or orange indicator never turns on because of Hector.
public enum CaptureDeviceReader {
    /// Object IDs of the devices behind a snapshot, so the monitor can listen to each one.
    struct Objects {
        var microphones: [AudioObjectID] = []
        var cameras: [CMIOObjectID] = []
    }

    /// What the cameras and microphones are doing right now.
    public static func snapshot() -> CaptureSnapshot {
        read().snapshot
    }

    static func read() -> (snapshot: CaptureSnapshot, objects: Objects) {
        var objects = Objects()
        let recordingPIDs = AudioHAL.recordingPIDs()
        let anyRecording: Bool? = recordingPIDs.map { !$0.isEmpty }

        var devices: [CaptureDevice] = []
        for id in AudioHAL.inputDevices() {
            objects.microphones.append(id)
            devices.append(AudioHAL.device(id, anyProcessRecording: anyRecording))
        }
        for id in CameraHAL.devices() {
            objects.cameras.append(id)
            devices.append(CameraHAL.device(id))
        }
        let users: [ProcessIdentity]? = recordingPIDs.map { pids in
            Array(Set(pids)).sorted().map(ProcessIdentity.resolve(pid:))
        }
        let snapshot = CaptureSnapshot(takenAt: Date(), devices: devices, microphoneUsers: users)
        return (snapshot, objects)
    }
}

// MARK: - Core Audio

enum AudioHAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func propertyAddress(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    }

    /// Size in bytes of a property's value, `nil` when the object does not have it.
    static func dataSize(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        return status == noErr ? size : nil
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var address = propertyAddress(selector)
        guard let byteCount = dataSize(object, address) else { return nil }
        let stride = MemoryLayout<AudioObjectID>.stride
        let count = Int(byteCount) / stride
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        var size = UInt32(count * stride)
        let status: OSStatus = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return nil }
        return Array(ids.prefix(Int(size) / stride))
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var address = propertyAddress(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// A CFString property. Core Audio returns it retained: the caller releases it.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status: OSStatus = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        let address = propertyAddress(AudioObjectPropertySelector(kAudioDevicePropertyStreams), scope: scope)
        let size = dataSize(device, address) ?? 0
        return Int(size) / MemoryLayout<AudioStreamID>.stride
    }

    /// Every audio device with at least one input stream: microphones, headsets, audio
    /// interfaces, virtual and aggregate devices.
    static func inputDevices() -> [AudioObjectID] {
        let all = objectList(systemObject, AudioObjectPropertySelector(kAudioHardwarePropertyDevices)) ?? []
        let input = AudioObjectPropertyScope(kAudioObjectPropertyScopeInput)
        return all.filter { streamCount($0, scope: input) > 0 }
    }

    static func device(_ id: AudioObjectID, anyProcessRecording: Bool?) -> CaptureDevice {
        let running = (uint32(id, AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere)) ?? 0) != 0
        let output = AudioObjectPropertyScope(kAudioObjectPropertyScopeOutput)
        let hasOutput = streamCount(id, scope: output) > 0
        let uid = string(id, AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID)) ?? "audio-\(id)"
        let name = string(id, AudioObjectPropertySelector(kAudioObjectPropertyName)) ?? "Audio input \(id)"
        let inUse = CaptureActivity.microphoneInUse(isRunningSomewhere: running, hasOutput: hasOutput,
                                                    anyProcessRecording: anyProcessRecording)
        return CaptureDevice(id: "microphone:\(uid)", kind: .microphone, name: name, isInUse: inUse,
                             isRunningSomewhere: running, hasOutput: hasOutput)
    }

    /// PIDs of the processes recording from any audio input device, from the Core Audio process
    /// objects (macOS 14 and later). `nil` when the list cannot be read.
    static func recordingPIDs() -> [Int32]? {
        let listSelector = AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList)
        guard let processes = objectList(systemObject, listSelector) else { return nil }
        let runningInput = AudioObjectPropertySelector(kAudioProcessPropertyIsRunningInput)
        let pidSelector = AudioObjectPropertySelector(kAudioProcessPropertyPID)
        return processes.compactMap { process -> Int32? in
            guard let running = uint32(process, runningInput), running != 0 else { return nil }
            guard let pid = int32(process, pidSelector), pid > 0 else { return nil }
            return pid
        }
    }
}

// MARK: - CoreMediaIO

enum CameraHAL {
    static let systemObject = CMIOObjectID(kCMIOObjectSystemObject)

    static func propertyAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        // Element 0 is kCMIOObjectPropertyElementMain (formerly ...ElementMaster).
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(0))
    }

    /// Every video device CoreMediaIO knows: built-in and USB cameras, Continuity Camera, virtual
    /// cameras.
    static func devices() -> [CMIOObjectID] {
        var address = propertyAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var byteCount: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &address, 0, nil, &byteCount) == noErr else { return [] }
        let stride = MemoryLayout<CMIOObjectID>.stride
        let count = Int(byteCount) / stride
        guard count > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        let status: OSStatus = ids.withUnsafeMutableBytes { bytes in
            CMIOObjectGetPropertyData(systemObject, &address, 0, nil, byteCount, &used, bytes.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(used) / stride))
    }

    static func uint32(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value)
        return status == noErr ? value : nil
    }

    /// A CFString property, returned retained like Core Audio's.
    static func string(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status: OSStatus = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func device(_ id: CMIOObjectID) -> CaptureDevice {
        let running = (uint32(id, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)) ?? 0) != 0
        let uid = string(id, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) ?? "cmio-\(id)"
        let name = string(id, CMIOObjectPropertySelector(kCMIOObjectPropertyName)) ?? "Camera \(id)"
        return CaptureDevice(id: "camera:\(uid)", kind: .camera, name: name, isInUse: running, isRunningSomewhere: running)
    }
}
