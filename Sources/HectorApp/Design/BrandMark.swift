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

    /// Two calm eyes, looking straight out.
    static func eyes() -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 9.05, y: 12.6, width: 1.3, height: 1.6))
        path.addEllipse(in: CGRect(x: 13.65, y: 12.6, width: 1.3, height: 1.6))
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
struct HectorMark: View {
    var lineWidth: CGFloat = 1.4
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
            context.fill(BrandGeometry.eyes(), with: .color(ink))
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
