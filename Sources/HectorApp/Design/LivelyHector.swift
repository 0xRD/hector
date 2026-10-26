import AppKit
import SwiftUI

/// Hector peeking over the map, alive but nearly free: the mark is drawn once, and only his eyes
/// move, on two small Core Animation layers.
///
/// A move (a blink, a glance along the lines, a look back) happens a few times a minute. Each one
/// is a short implicit animation that the window server plays; between moves the app does
/// nothing and nothing is redrawn. A timer with a generous tolerance schedules the moves, so
/// macOS can fold its wake-ups into others. While the window is hidden or covered, under Reduce
/// Motion, or while monitoring is paused, Hector holds still.
///
/// The 0.4.8 animation redrew the whole mark 30 times a second (a sixth of a core); this one
/// costs a handful of property changes a minute.
struct LivelyHectorPeek: View {
    /// Something on the map is hovered: Hector looks at it, eyes a little wider.
    var isAttentive: Bool
    /// Monitoring is paused: eyes closed.
    var isResting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isResting || reduceMotion {
            HectorPeek(gaze: isResting ? .resting : .right)
        } else {
            HectorPeek(gaze: .right, showsEyes: false)
                .overlay {
                    GeometryReader { proxy in
                        HectorEyes(isAttentive: isAttentive)
                            // The mark is a square as wide as the peek, from its top.
                            .frame(width: proxy.size.width, height: proxy.size.width)
                    }
                }
        }
    }
}

/// Hector's two eyes as layers over the mark's 24-point grid.
private struct HectorEyes: NSViewRepresentable {
    var isAttentive: Bool

    func makeNSView(context: Context) -> EyesView { EyesView() }

    func updateNSView(_ view: EyesView, context: Context) {
        view.isAttentive = isAttentive
    }

    static func dismantleNSView(_ view: EyesView, coordinator: ()) {
        view.stop()
    }

    final class EyesView: NSView {
        /// Grid positions, as in `BrandGeometry.eyes`: centers and size of each open eye.
        private static let centers: [CGPoint] = [CGPoint(x: 9.7, y: 13.4), CGPoint(x: 14.3, y: 13.4)]
        private static let size = CGSize(width: 1.3, height: 1.6)
        /// Looking right, toward the lines, like the still peek.
        private static let restingShift: CGFloat = 0.75

        private let eyes = [CAShapeLayer(), CAShapeLayer()]
        private var timer: Timer?
        private var step = 0

        var isAttentive = false {
            didSet {
                guard isAttentive != oldValue else { return }
                // Wider and fixed on what is hovered; back to the routine after.
                move(x: Self.restingShift, y: isAttentive ? 0.15 : 0, open: isAttentive ? 1.15 : 1, duration: 0.18)
            }
        }

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for eye in eyes {
                eye.actions = nil
                layer?.addSublayer(eye)
            }
        }

        required init?(coder: NSCoder) { nil }

        // Clicks and hovers go to the map underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let scale = bounds.width / BrandGeometry.grid
            let size = CGSize(width: Self.size.width * scale, height: Self.size.height * scale)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (eye, center) in zip(eyes, Self.centers) {
                eye.bounds = CGRect(origin: .zero, size: size)
                eye.path = CGPath(ellipseIn: eye.bounds, transform: nil)
                eye.position = CGPoint(x: center.x * scale, y: center.y * scale)
            }
            CATransaction.commit()
            applyInk()
            move(x: Self.restingShift, y: 0, open: 1, duration: 0)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyInk()
        }

        private func applyInk() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let ink = NSColor(Color.hectorInfo).cgColor
                for eye in eyes { eye.fillColor = ink }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { schedule() }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        /// The routine, one move per tick: blinks, a glance along the lines and back, a look down
        /// at the map, a double blink now and then.
        private static let routine: [(delay: TimeInterval, move: Move)] = [
            (4.5, .blink), (3.0, .glance(x: -0.6, y: 0)), (1.6, .back),
            (5.0, .blink), (4.0, .glance(x: 0.75, y: 0.4)), (2.2, .back),
            (6.0, .doubleBlink), (3.5, .glance(x: 0, y: -0.3)), (1.4, .back),
        ]

        private enum Move {
            case blink
            case doubleBlink
            case glance(x: CGFloat, y: CGFloat)
            case back
        }

        private func schedule() {
            stop()
            let entry = Self.routine[step % Self.routine.count]
            let timer = Timer(timeInterval: entry.delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(entry.move) }
            }
            // A move a little late is invisible; letting macOS batch wake-ups saves power.
            timer.tolerance = entry.delay * 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick(_ move: Move) {
            step += 1
            defer { schedule() }
            // Hidden, minimized or covered: skip the move, keep the rhythm.
            guard let window, window.occlusionState.contains(.visible), !isAttentive else { return }
            switch move {
            case .blink:
                blink(after: 0)
            case .doubleBlink:
                blink(after: 0)
                blink(after: 0.32)
            case .glance(let x, let y):
                self.move(x: x, y: y, open: 1, duration: 0.25)
            case .back:
                self.move(x: Self.restingShift, y: 0, open: 1, duration: 0.3)
            }
        }

        private func blink(after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.setOpenness(0.1, duration: 0.07)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
                    self?.setOpenness(self?.isAttentive == true ? 1.15 : 1, duration: 0.1)
                }
            }
        }

        private var shift = CGPoint(x: restingShift, y: 0)
        private var openness: CGFloat = 1

        private func move(x: CGFloat, y: CGFloat, open: CGFloat, duration: TimeInterval) {
            shift = CGPoint(x: x, y: y)
            openness = open
            apply(duration: duration)
        }

        private func setOpenness(_ open: CGFloat, duration: TimeInterval) {
            openness = open
            apply(duration: duration)
        }

        /// One implicit animation, played by the window server.
        private func apply(duration: TimeInterval) {
            let scale = bounds.width / BrandGeometry.grid
            var transform = CATransform3DMakeTranslation(shift.x * scale, shift.y * scale, 0)
            transform = CATransform3DScale(transform, openness > 1 ? openness : 1, openness, 1)
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            CATransaction.setDisableActions(duration == 0)
            for eye in eyes {
                if duration > 0 {
                    let animation = CABasicAnimation(keyPath: "transform")
                    animation.fromValue = eye.presentation()?.transform ?? eye.transform
                    animation.toValue = transform
                    animation.duration = duration
                    eye.add(animation, forKey: "move")
                }
                eye.transform = transform
            }
            CATransaction.commit()
        }
    }
}
