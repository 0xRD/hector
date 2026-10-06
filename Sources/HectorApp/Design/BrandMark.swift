import SwiftUI

// The brand marks, drawn in code on a 24 × 24 grid (like SF Symbols).
//
// - `HectorMark`: the app. Hector, the defender of Troy, seen from the front: a rounded
//   Corinthian helmet with a clay crest that leans a little to one side, and a calm face
//   looking out through the visor. The one who holds fast, without making a fuss about it.
// - `NetbiteLogo`: the network module. A globe with a bite taken out of it.
//
// See docs/DESIGN.md, "Brand marks".

/// Geometry of the marks.
enum BrandGeometry {
    static let grid: CGFloat = 24

    // MARK: Hector

    /// The crest leans this much (radians, about 7° to the left): the one quirk of the mark.
    static let crestTilt: CGFloat = -0.12

    /// The helmet: a dome, two cheek guards, and a T-shaped opening (a horizontal visor slot and
    /// the gap between the cheek guards). One closed contour, so it fills and strokes cleanly.
    static func helmet() -> Path {
        var path = Path()
        // Left cheek guard, from the bottom of the gap.
        path.move(to: CGPoint(x: 10.7, y: 22.4))
        path.addQuadCurve(to: CGPoint(x: 5.0, y: 17.4), control: CGPoint(x: 5.6, y: 22.4))
        path.addLine(to: CGPoint(x: 5.0, y: 13.2))
        // The dome.
        path.addCurve(to: CGPoint(x: 12.0, y: 5.8), control1: CGPoint(x: 5.0, y: 8.8), control2: CGPoint(x: 8.2, y: 5.8))
        path.addCurve(to: CGPoint(x: 19.0, y: 13.2), control1: CGPoint(x: 15.8, y: 5.8), control2: CGPoint(x: 19.0, y: 8.8))
        // Right cheek guard.
        path.addLine(to: CGPoint(x: 19.0, y: 17.4))
        path.addQuadCurve(to: CGPoint(x: 13.3, y: 22.4), control: CGPoint(x: 18.4, y: 22.4))
        // Up the gap, then around the visor slot.
        path.addLine(to: CGPoint(x: 13.3, y: 15.0))
        path.addLine(to: CGPoint(x: 15.0, y: 15.0))
        path.addArc(tangent1End: CGPoint(x: 16.6, y: 15.0), tangent2End: CGPoint(x: 16.6, y: 11.8), radius: 1.6)
        path.addArc(tangent1End: CGPoint(x: 16.6, y: 11.8), tangent2End: CGPoint(x: 15.0, y: 11.8), radius: 1.6)
        path.addLine(to: CGPoint(x: 9.0, y: 11.8))
        path.addArc(tangent1End: CGPoint(x: 7.4, y: 11.8), tangent2End: CGPoint(x: 7.4, y: 15.0), radius: 1.6)
        path.addArc(tangent1End: CGPoint(x: 7.4, y: 15.0), tangent2End: CGPoint(x: 9.0, y: 15.0), radius: 1.6)
        path.addLine(to: CGPoint(x: 10.7, y: 15.0))
        path.closeSubpath()
        return path
    }

    /// The face behind the helmet. Only the visor, the gap and the chin (just below the cheek
    /// guards) show; the rest is covered by the helmet.
    static func face() -> Path {
        Path(roundedRect: CGRect(x: 6.8, y: 9.0, width: 10.4, height: 14.2), cornerRadius: 5.0, style: .continuous)
    }

    /// Two calm eyes, looking straight out, to one side, or resting (filled when open, stroked
    /// when resting).
    static func eyes(_ gaze: HectorGaze = .ahead) -> Path {
        switch gaze {
        case .left: return eyes(HectorEyes(x: -0.75))
        case .right: return eyes(HectorEyes(x: 0.75))
        case .ahead: return eyes(HectorEyes())
        case .resting:
            var path = Path()
            for cx in [9.7, 14.3] as [CGFloat] {
                // Closed and content: a small downward curve.
                path.move(to: CGPoint(x: cx - 0.75, y: 13.3))
                path.addQuadCurve(to: CGPoint(x: cx + 0.75, y: 13.3), control: CGPoint(x: cx, y: 14.1))
            }
            return path
        }
    }

    /// Open eyes at any position and openness, for the animated appearances.
    static func eyes(_ pose: HectorEyes) -> Path {
        var path = Path()
        // Kept inside the visor slot (11.8 to 15.0).
        let height = 1.6 * min(max(pose.openness, 0.08), 1.15)
        let centerY = 13.4 + min(max(pose.y, -0.5), 0.5)
        for x in [9.7, 14.3] as [CGFloat] {
            let cx = x + min(max(pose.x, -0.9), 0.9)
            path.addEllipse(in: CGRect(x: cx - 0.65, y: centerY - height / 2, width: 1.3, height: height))
        }
        return path
    }

    /// A small, closed-mouth smile, in the gap between the cheek guards.
    static func smile() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 11.3, y: 18.7))
        path.addQuadCurve(to: CGPoint(x: 12.7, y: 18.7), control: CGPoint(x: 12.0, y: 19.5))
        return path
    }

    /// A highlight on the upper left of the dome.
    static func shine() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 7.0, y: 10.6))
        path.addQuadCurve(to: CGPoint(x: 9.8, y: 7.6), control: CGPoint(x: 7.4, y: 8.2))
        return path
    }

    /// The crest: a fan of horsehair flaring out of the dome. Its base is hidden by the helmet.
    static func crest() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 10.4, y: 7.4))
        path.addQuadCurve(to: CGPoint(x: 6.0, y: 3.2), control: CGPoint(x: 8.6, y: 5.6))
        path.addCurve(to: CGPoint(x: 12.0, y: 0.5), control1: CGPoint(x: 6.4, y: 1.4), control2: CGPoint(x: 9.2, y: 0.5))
        path.addCurve(to: CGPoint(x: 18.0, y: 3.2), control1: CGPoint(x: 14.8, y: 0.5), control2: CGPoint(x: 17.6, y: 1.4))
        path.addQuadCurve(to: CGPoint(x: 13.6, y: 7.4), control: CGPoint(x: 15.4, y: 5.6))
        path.closeSubpath()
        return tilted(path)
    }

    /// Two strands combed into the crest, following its flare.
    static func crestStrands() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 11.3, y: 6.6))
        path.addQuadCurve(to: CGPoint(x: 8.6, y: 2.2), control: CGPoint(x: 9.6, y: 4.4))
        path.move(to: CGPoint(x: 12.7, y: 6.6))
        path.addQuadCurve(to: CGPoint(x: 15.4, y: 2.2), control: CGPoint(x: 14.4, y: 4.4))
        return tilted(path)
    }

    /// Applies the crest's lean, around the top of the dome.
    private static func tilted(_ path: Path) -> Path {
        let pivotX: CGFloat = 12
        let pivotY: CGFloat = 8
        let transform = CGAffineTransform(translationX: pivotX, y: pivotY)
            .rotated(by: crestTilt)
            .translatedBy(x: -pivotX, y: -pivotY)
        return path.applying(transform)
    }

    // MARK: Netbite

    /// The globe of the network module.
    static func globe() -> Path {
        var globe = Path()
        globe.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
        globe.addEllipse(in: CGRect(x: 7.8, y: 2.5, width: 8.4, height: 19))
        globe.move(to: CGPoint(x: 2.5, y: 12))
        globe.addLine(to: CGPoint(x: 21.5, y: 12))
        globe.move(to: CGPoint(x: 4.2, y: 7.3))
        globe.addLine(to: CGPoint(x: 19.8, y: 7.3))
        globe.move(to: CGPoint(x: 4.2, y: 16.7))
        globe.addLine(to: CGPoint(x: 19.8, y: 16.7))
        return globe
    }

    /// Everything but the bite in the globe's top-right edge; clip with `FillStyle(eoFill: true)`.
    static func biteMask() -> Path {
        var mask = Path(CGRect(x: -2, y: -2, width: grid + 4, height: grid + 4))
        mask.addEllipse(in: CGRect(x: 16.5, y: -0.5, width: 10, height: 10))
        return mask
    }
}

/// The Hector mark: a crested helmet with a calm face behind the visor. Adapts to light and dark
/// mode by default; the app icon passes the fixed brand colors.
///
/// Below 28 pt the mark drops its small details (eyes, smile, strands, shine) and keeps the
/// silhouette, the visor and the crest, which stay legible down to 16 pt.
///
///     HectorMark().frame(width: 64, height: 64)
/// Where Hector looks. The mark looks ahead; the app's small appearances turn his eyes toward
/// what he watches, or close them while he rests.
enum HectorGaze {
    case ahead
    case left
    case right
    case resting
}

/// Where open eyes look, in grid units from straight ahead (x to the right, y down), and how
/// open they are (1: open, 0: shut).
struct HectorEyes: Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var openness: CGFloat = 1
}

struct HectorMark: View {
    var lineWidth: CGFloat = 1.4
    var gaze: HectorGaze = .ahead
    /// Outlines, eyes and smile.
    var ink: Color = .hectorInfo
    /// Fill of the helmet, top to bottom.
    var helmet: [Color] = [.hectorHelmet, .hectorHelmetShade]
    /// The face behind the visor.
    var face: Color = .brandCream
    /// The crest.
    var crest: Color = .hectorCrest
    /// Forces the small details on or off; `nil` decides from the size.
    var detailed: Bool? = nil
    /// Overrides `gaze` with eyes at any position, for the animated appearances.
    var eyes: HectorEyes? = nil

    var body: some View {
        Canvas { context, size in
            let side: CGFloat = min(size.width, size.height)
            let scale: CGFloat = side / BrandGeometry.grid
            let showsDetail: Bool = detailed ?? (side >= 28)
            context.scaleBy(x: scale, y: scale)
            drawCrest(in: context, detailed: showsDetail)
            drawFace(in: context, detailed: showsDetail)
            drawHelmet(in: context, detailed: showsDetail)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var outline: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }

    private func drawCrest(in context: GraphicsContext, detailed: Bool) {
        let shape = BrandGeometry.crest()
        context.fill(shape, with: .color(crest))
        if detailed {
            let strands = StrokeStyle(lineWidth: lineWidth * 0.5, lineCap: .round)
            context.stroke(BrandGeometry.crestStrands(), with: .color(ink.opacity(0.45)), style: strands)
        }
        context.stroke(shape, with: .color(ink), style: outline)
    }

    private func drawFace(in context: GraphicsContext, detailed: Bool) {
        let shape = BrandGeometry.face()
        context.fill(shape, with: .color(face))
        context.stroke(shape, with: .color(ink), style: outline)
        if detailed {
            if let eyes {
                context.fill(BrandGeometry.eyes(eyes), with: .color(ink))
            } else if gaze == .resting {
                context.stroke(BrandGeometry.eyes(gaze), with: .color(ink), style: StrokeStyle(lineWidth: lineWidth * 0.6, lineCap: .round))
            } else {
                context.fill(BrandGeometry.eyes(gaze), with: .color(ink))
            }
            let mouth = StrokeStyle(lineWidth: lineWidth * 0.55, lineCap: .round)
            context.stroke(BrandGeometry.smile(), with: .color(ink), style: mouth)
        }
    }

    private func drawHelmet(in context: GraphicsContext, detailed: Bool) {
        let shape = BrandGeometry.helmet()
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: helmet),
            startPoint: CGPoint(x: 12, y: 5.8),
            endPoint: CGPoint(x: 12, y: 22.4)
        )
        context.fill(shape, with: shading)
        if detailed {
            let shine = StrokeStyle(lineWidth: lineWidth * 0.7, lineCap: .round)
            context.stroke(BrandGeometry.shine(), with: .color(.white.opacity(0.45)), style: shine)
        }
        context.stroke(shape, with: .color(ink), style: outline)
    }
}

/// Hector peeking over an edge: the top of the mark, cut off where the edge is. Place it with
/// its bottom on the edge he hides behind.
///
///     HectorPeek(gaze: .right).frame(width: 40)
struct HectorPeek: View {
    var gaze: HectorGaze = .ahead
    /// How much of the mark shows, from the top (0.6: crest, helmet and eyes).
    var showing: CGFloat = 0.62

    var body: some View {
        GeometryReader { proxy in
            HectorMark(gaze: gaze, detailed: true)
                .frame(width: proxy.size.width, height: proxy.size.width)
                .frame(height: proxy.size.height, alignment: .top)
                .clipped()
        }
        .aspectRatio(1 / showing, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Hector on watch over the map: he peeks over its bottom edge, sweeps it with his eyes, blinks,
/// now and then hoists himself up for a better look, and turns attentive while a line is pointed
/// at. Rests (eyes closed) while live updates are paused.
///
/// Driven by a `TimelineView` rather than state: the pose is a pure function of the time, so no
/// `@State` is needed (see `WindowState`). Still under Reduce Motion.
struct WatchingHector: View {
    /// A line or a country is under the pointer.
    var isAttentive = false
    /// Live updates are paused: Hector rests.
    var isResting = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much of the mark shows at rest, from the top, as in `HectorPeek`.
    private static let showing: CGFloat = 0.62
    /// How much more shows at the top of a hoist.
    private static let hoist: CGFloat = 0.16

    var body: some View {
        if reduceMotion || isResting {
            HectorPeek(gaze: isResting ? .resting : .right, showing: Self.showing)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                frame(eyes: eyes(at: time), rise: rise(at: time))
            }
        }
    }

    /// The mark in a frame tall enough for the hoist, clipped where the edge is.
    private func frame(eyes: HectorEyes, rise: CGFloat) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HectorMark(detailed: true, eyes: eyes)
                .frame(width: width, height: width)
                .offset(y: (Self.hoist - rise * Self.hoist) * width)
                .frame(height: proxy.size.height, alignment: .top)
                .clipped()
        }
        .aspectRatio(1 / (Self.showing + Self.hoist), contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// The eyes sweep the map on a slow loop (right, up the middle, left, back), and blink.
    private func eyes(at time: TimeInterval) -> HectorEyes {
        var eyes: HectorEyes
        if isAttentive {
            // Wide open, toward the lines above.
            eyes = HectorEyes(x: 0.55, y: -0.35, openness: 1.12)
        } else {
            // (seconds into the loop, x, y): held a while at each point, eased in between.
            let path: [(TimeInterval, CGFloat, CGFloat)] = [
                (0, 0.75, -0.1), (3.5, 0.75, -0.1), (4.4, 0.1, -0.4), (6.0, 0.1, -0.4),
                (6.9, -0.75, -0.15), (9.4, -0.75, -0.15), (10.3, 0.0, 0.1), (11.4, 0.0, 0.1),
                (12.3, 0.75, -0.1), (15.0, 0.75, -0.1),
            ]
            let t = time.truncatingRemainder(dividingBy: 15)
            let next = path.firstIndex { $0.0 > t } ?? path.count - 1
            let (t0, x0, y0) = path[max(next - 1, 0)]
            let (t1, x1, y1) = path[next]
            let progress = Self.ease(CGFloat((t - t0) / max(t1 - t0, 0.001)))
            eyes = HectorEyes(x: x0 + (x1 - x0) * progress, y: y0 + (y1 - y0) * progress)
        }
        eyes.openness *= blink(at: time)
        return eyes
    }

    /// 1 with the eyes open, down to 0 for a blink every 4.6 s, twice in a row every third time.
    private func blink(at time: TimeInterval) -> CGFloat {
        let period: TimeInterval = 4.6
        let duration: TimeInterval = 0.16
        let cycle = Int(time / period)
        let t = time.truncatingRemainder(dividingBy: period)
        let starts: [TimeInterval] = cycle % 3 == 0 ? [0, 0.28] : [0]
        for start in starts where t >= start && t < start + duration {
            return 1 - sin(CGFloat((t - start) / duration) * .pi)
        }
        return 1
    }

    /// 0 at rest, up to 1 when he hoists himself up: once every 19 s, for about 2.5 s.
    private func rise(at time: TimeInterval) -> CGFloat {
        if isAttentive { return 0.35 }
        let t = time.truncatingRemainder(dividingBy: 19)
        let start: TimeInterval = 13
        switch t {
        case start..<(start + 0.5): return Self.ease(CGFloat((t - start) / 0.5))
        case (start + 0.5)..<(start + 2.2): return 1
        case (start + 2.2)..<(start + 2.8): return 1 - Self.ease(CGFloat((t - start - 2.2) / 0.6))
        default: return 0
        }
    }

    private static func ease(_ x: CGFloat) -> CGFloat {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

/// The Netbite network module glyph: a globe with a bite out of its top-right edge.
/// Use it where the network module is named (its sidebar entry, its screens).
///
///     NetbiteLogo().frame(width: 18, height: 18)
struct NetbiteLogo: View {
    var lineWidth: CGFloat = 1.7
    var color: Color = .hectorOK

    var body: some View {
        Canvas { context, size in
            let scale: CGFloat = min(size.width, size.height) / BrandGeometry.grid
            context.scaleBy(x: scale, y: scale)
            context.clip(to: BrandGeometry.biteMask(), style: FillStyle(eoFill: true))
            context.stroke(BrandGeometry.globe(), with: .color(color), lineWidth: lineWidth)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The mark followed by the name in the serif display face, for About, onboarding and other
/// places where Hector introduces itself.
///
///     HectorWordmark(size: 28)
struct HectorWordmark: View {
    var name = "Hector"
    var size: CGFloat = 24

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.3) {
            HectorMark()
                .frame(width: size * 1.4, height: size * 1.4)
            Text(name)
                .font(.system(size: size, weight: .semibold, design: .serif))
                .tracking(-0.2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

/// The walls of Troy: courses of ashlar under a coping, for the bottom of the app icon.
struct RampartPattern: View {
    var stone: Color = .brandStone
    var joint: Color = .brandStoneDeep
    var edge: Color = .brandPlum
    var course: CGFloat = 38
    var block: CGFloat = 76

    var body: some View {
        Canvas { context, size in
            let coping: CGFloat = course * 0.34
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(stone))
            let band = CGRect(x: 0, y: 0, width: size.width, height: coping)
            context.fill(Path(band), with: .color(Color.white.opacity(0.22)))
            context.stroke(joints(size: size, top: coping), with: .color(joint), lineWidth: 3)
            var top = Path()
            top.move(to: CGPoint(x: 0, y: 2.5))
            top.addLine(to: CGPoint(x: size.width, y: 2.5))
            context.stroke(top, with: .color(edge), lineWidth: 5)
        }
        .accessibilityHidden(true)
    }

    /// Horizontal beds and staggered vertical joints, one row of blocks per course.
    private func joints(size: CGSize, top: CGFloat) -> Path {
        var path = Path()
        let rows = Int((size.height - top) / course) + 1
        let columns = Int(size.width / block) + 2
        for row in 0..<rows {
            let y: CGFloat = top + CGFloat(row) * course
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            let offset: CGFloat = row % 2 == 0 ? block * 0.35 : block * 0.85
            for column in 0..<columns {
                let x: CGFloat = offset + CGFloat(column) * block - block
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + course))
            }
        }
        return path
    }
}
