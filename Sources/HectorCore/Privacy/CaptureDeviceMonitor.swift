import CoreAudio
import CoreMediaIO
import Foundation

/// Watches cameras and microphones and reports when they turn on or off, and which app records
/// from the microphone when Core Audio says so.
///
/// Property listeners (Core Audio and CoreMediaIO, block-based, on a private serial queue) only
/// signal that something changed; the state is then read again on the main actor and compared
/// with the previous one. A light poll (every 2 s by default) catches what has no listener:
/// apps starting or stopping to record while the microphone stays on.
///
/// Call `stop()` before dropping the monitor: it removes every listener.
@MainActor
public final class CaptureDeviceMonitor {
    public typealias Handler = @MainActor (CaptureSnapshot, [CaptureEvent]) -> Void

    public private(set) var isRunning = false
    public private(set) var latest: CaptureSnapshot?

    private let handler: Handler
    private let pollInterval: Duration
    private var tracker = CaptureActivityTracker()
    private let queue = DispatchQueue(label: "io.github.0xrd.hector.capture-listeners")
    private var signal: AsyncStream<Void>.Continuation?
    private var consumer: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var audioListeners: [AudioListener] = []
    private var cameraListeners: [CameraListener] = []

    private struct AudioListener {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    private struct CameraListener {
        let object: CMIOObjectID
        let selector: CMIOObjectPropertySelector
        let block: CMIOObjectPropertyListenerBlock
    }

    /// - Parameter handler: called on the main actor after each read, with the events since the
    ///   previous read (often none). The first read reports devices already on as `alreadyOn`.
    public init(pollInterval: Duration = .seconds(2), handler: @escaping Handler) {
        self.pollInterval = pollInterval
        self.handler = handler
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        tracker = CaptureActivityTracker()

        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        signal = continuation
        consumer = Task { [weak self] in
            for await _ in stream {
                // Let a burst of notifications (device, then process list) settle into one read.
                try? await Task.sleep(for: .milliseconds(250))
                self?.refresh()
            }
        }
        let interval = pollInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }

        let system = AudioHAL.systemObject
        addAudioListener(system, AudioObjectPropertySelector(kAudioHardwarePropertyDevices))
        addAudioListener(system, AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList))
        addCameraListener(CameraHAL.systemObject, CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        refresh()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        for listener in audioListeners {
            var address = AudioHAL.propertyAddress(listener.selector)
            _ = AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        for listener in cameraListeners {
            var address = CameraHAL.propertyAddress(listener.selector)
            _ = CMIOObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        audioListeners = []
        cameraListeners = []
        signal?.finish()
        signal = nil
        consumer?.cancel()
        consumer = nil
        poller?.cancel()
        poller = nil
    }

    /// Reads every device again, reports the changes and follows devices that appeared.
    public func refresh() {
        guard isRunning else { return }
        let (snapshot, objects) = CaptureDeviceReader.read()
        watch(microphones: objects.microphones, cameras: objects.cameras)
        latest = snapshot
        let events = tracker.update(with: snapshot)
        handler(snapshot, events)
    }

    // MARK: - Listeners

    /// One "running somewhere" listener per device; listeners of devices that are gone are removed.
    private func watch(microphones: [AudioObjectID], cameras: [CMIOObjectID]) {
        let audioRunning = AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let cameraRunning = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)

        let watchedAudio = Set(audioListeners.filter { $0.selector == audioRunning }.map(\.object))
        for id in microphones where !watchedAudio.contains(id) { addAudioListener(id, audioRunning) }
        let liveAudio = Set(microphones)
        for listener in audioListeners where listener.selector == audioRunning && !liveAudio.contains(listener.object) {
            var address = AudioHAL.propertyAddress(listener.selector)
            _ = AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        audioListeners.removeAll { $0.selector == audioRunning && !liveAudio.contains($0.object) }

        let watchedCameras = Set(cameraListeners.filter { $0.selector == cameraRunning }.map(\.object))
        for id in cameras where !watchedCameras.contains(id) { addCameraListener(id, cameraRunning) }
        let liveCameras = Set(cameras)
        for listener in cameraListeners where listener.selector == cameraRunning && !liveCameras.contains(listener.object) {
            var address = CameraHAL.propertyAddress(listener.selector)
            _ = CMIOObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        cameraListeners.removeAll { $0.selector == cameraRunning && !liveCameras.contains($0.object) }
    }

    private func addAudioListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        guard let signal else { return }
        var address = AudioHAL.propertyAddress(selector)
        let block = Self.audioBlock(signal)
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            audioListeners.append(AudioListener(object: object, selector: selector, block: block))
        }
    }

    private func addCameraListener(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) {
        guard let signal else { return }
        var address = CameraHAL.propertyAddress(selector)
        let block = Self.cameraBlock(signal)
        if CMIOObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            cameraListeners.append(CameraListener(object: object, selector: selector, block: block))
        }
    }

    // The blocks run on `queue`, outside the main actor. They are built in nonisolated functions so
    // they inherit no actor isolation, and they touch nothing but the continuation, which is
    // Sendable: the read itself happens on the main actor, in the consumer task.

    nonisolated private static func audioBlock(_ signal: AsyncStream<Void>.Continuation) -> AudioObjectPropertyListenerBlock {
        { _, _ in _ = signal.yield() }
    }

    nonisolated private static func cameraBlock(_ signal: AsyncStream<Void>.Continuation) -> CMIOObjectPropertyListenerBlock {
        { _, _ in _ = signal.yield() }
    }
}
