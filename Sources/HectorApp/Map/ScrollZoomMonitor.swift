import AppKit
import SwiftUI

/// ⌘ and the scroll wheel (or two fingers on a trackpad) over the map. SwiftUI has no scroll-wheel
/// event, so an AppKit view under the map watches the window's scroll events: only those over
/// it with ⌘ held are taken; every other scroll goes on as usual.
struct ScrollZoomMonitor: NSViewRepresentable {
    /// A zoom factor (above 1 zooms in) and the point under the pointer, in the view's
    /// coordinates (origin at the top left, like SwiftUI's).
    let onZoom: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onZoom = onZoom
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    /// The zoom factor for one scroll event: a mouse wheel moves in notches, a trackpad in points.
    static func factor(deltaY: CGFloat, precise: Bool) -> CGFloat {
        let factor = precise ? pow(1.01, deltaY) : pow(1.2, deltaY)
        return min(max(factor, 0.5), 2)
    }

    final class MonitorView: NSView {
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        // Clicks, hovers and gestures go to the SwiftUI map above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.modifierFlags.contains(.command), event.scrollingDeltaY != 0,
                      let point = self.location(of: event), self.bounds.contains(point) else { return event }
                self.onZoom?(ScrollZoomMonitor.factor(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas), point)
                return nil
            }
        }

        /// The event's point in this view. An event with no window (posted by software) carries
        /// screen coordinates: it counts only where this window is the one on screen there.
        private func location(of event: NSEvent) -> CGPoint? {
            guard let window else { return nil }
            if event.window === window { return convert(event.locationInWindow, from: nil) }
            guard event.window == nil,
                  Self.skipsWindowCheck || NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0) == window.windowNumber
            else { return nil }
            return convert(window.convertPoint(fromScreen: event.locationInWindow), from: nil)
        }

        /// `HECTOR_DEBUG_SCROLL` (debug builds) scrolls a window other apps may cover.
        private static var skipsWindowCheck: Bool {
            #if DEBUG
            ProcessInfo.processInfo.environment["HECTOR_DEBUG_SCROLL"] != nil
            #else
            false
            #endif
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
