import SwiftUI

// The brand marks, drawn in code on a 24 × 24 grid (like SF Symbols).
//
// - `HexorcistMark`: the app. A rounded hexagon seal (the "ward") holding a small, friendly
//   ghost: the hex being shown the door. A honey spark breaks through the seal's top-right edge.
// - `NetbiteLogo`: the network module. A globe with a bite taken out of it.

/// Geometry of the marks.
enum BrandGeometry {
    static let grid: CGFloat = 24

    // MARK: Hexorcist

    /// The seal: a rounded, pointy-top hexagon.
    static func ward() -> Path {
        hexagonPath(in: CGRect(x: 1.4, y: 1.0, width: 21.2, height: 22.0), cornerRadius: 2.4)
    }

    /// Where the spark breaks the seal.
    static let sparkCenter = CGPoint(x: 19.4, y: 4.6)

    /// Everything but a disc around the spark; clip the seal with `FillStyle(eoFill: true)`.
    static func sealMask() -> Path {
        var mask = Path(CGRect(x: -2, y: -2, width: grid + 4, height: grid + 4))
        mask.addEllipse(in: CGRect(x: sparkCenter.x - 3.4, y: sparkCenter.y - 3.4, width: 6.8, height: 6.8))
        return mask
    }

    /// The ghost: a dome, straight sides, and a hem of three scallops.
    static func ghost() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 7.4, y: 11.0))
        path.addCurve(to: CGPoint(x: 12.0, y: 6.2), control1: CGPoint(x: 7.4, y: 8.2), control2: CGPoint(x: 9.4, y: 6.2))
        path.addCurve(to: CGPoint(x: 16.6, y: 11.0), control1: CGPoint(x: 14.6, y: 6.2), control2: CGPoint(x: 16.6, y: 8.2))
        path.addLine(to: CGPoint(x: 16.6, y: 17.4))
        path.addQuadCurve(to: CGPoint(x: 13.53, y: 17.4), control: CGPoint(x: 15.07, y: 19.2))
        path.addQuadCurve(to: CGPoint(x: 10.47, y: 17.4), control: CGPoint(x: 12.0, y: 19.2))
        path.addQuadCurve(to: CGPoint(x: 7.4, y: 17.4), control: CGPoint(x: 8.93, y: 19.2))
        path.closeSubpath()
        return path
    }

    /// The ghost's eyes, looking slightly up and to the right (toward the exit).
    static func eyes() -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 10.0, y: 10.0, width: 1.4, height: 1.9))
        path.addEllipse(in: CGRect(x: 13.2, y: 10.0, width: 1.4, height: 1.9))
        return path
    }

    /// A four-point spark centered on `center`.
    static func spark(center: CGPoint, radius: CGFloat) -> Path {
        let waist: CGFloat = radius * 0.2
        let x: CGFloat = center.x
        let y: CGFloat = center.y
        var path = Path()
        path.move(to: CGPoint(x: x, y: y - radius))
        path.addQuadCurve(to: CGPoint(x: x + radius, y: y), control: CGPoint(x: x + waist, y: y - waist))
        path.addQuadCurve(to: CGPoint(x: x, y: y + radius), control: CGPoint(x: x + waist, y: y + waist))
        path.addQuadCurve(to: CGPoint(x: x - radius, y: y), control: CGPoint(x: x - waist, y: y + waist))
        path.addQuadCurve(to: CGPoint(x: x, y: y - radius), control: CGPoint(x: x - waist, y: y - waist))
        path.closeSubpath()
        return path
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

/// The Hexorcist mark. Adapts to light and dark mode by default; the app icon passes the fixed
/// brand colors.
///
///     HexorcistMark().frame(width: 64, height: 64)
struct HexorcistMark: View {
    var lineWidth: CGFloat = 1.6
    /// Gradient of the seal, top-left to bottom-right.
    var seal: [Color] = [.hexInfo, .hexOK]
    /// Body of the ghost.
    var ghost: Color = .hexInfoWash
    /// Eyes and outline of the ghost.
    var eyes: Color = .hexInfo
    /// The spark.
    var spark: Color = .hexWarning

    var body: some View {
        Canvas { context, size in
            let scale: CGFloat = min(size.width, size.height) / BrandGeometry.grid
            context.scaleBy(x: scale, y: scale)
            var sealed = context
            sealed.clip(to: BrandGeometry.sealMask(), style: FillStyle(eoFill: true))
            drawSeal(in: sealed)
            drawGhost(in: context)
            drawSpark(in: context)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func drawSeal(in context: GraphicsContext) {
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: seal),
            startPoint: CGPoint(x: 2, y: 2),
            endPoint: CGPoint(x: 22, y: 22)
        )
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        context.stroke(BrandGeometry.ward(), with: shading, style: style)
    }

    private func drawGhost(in context: GraphicsContext) {
        let shape = BrandGeometry.ghost()
        context.fill(shape, with: .color(ghost))
        let outline: CGFloat = lineWidth * 0.55
        context.stroke(shape, with: .color(eyes.opacity(0.55)), style: StrokeStyle(lineWidth: outline, lineJoin: .round))
        context.fill(BrandGeometry.eyes(), with: .color(eyes))
    }

    private func drawSpark(in context: GraphicsContext) {
        context.fill(BrandGeometry.spark(center: BrandGeometry.sparkCenter, radius: 2.5), with: .color(spark))
        let small = BrandGeometry.spark(center: CGPoint(x: 22.4, y: 8.4), radius: 1.0)
        context.fill(small, with: .color(spark.opacity(0.7)))
    }
}

/// The Netbite network module glyph: a globe with a bite out of its top-right edge.
/// Use it where the network module is named (its sidebar entry, its screens).
///
///     NetbiteLogo().frame(width: 18, height: 18)
struct NetbiteLogo: View {
    var lineWidth: CGFloat = 1.7
    var color: Color = .hexOK

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

/// The mark followed by the name in the serif display face, for an About panel, onboarding or
/// the top of the sidebar after the rename.
///
///     HexorcistWordmark(size: 28)
struct HexorcistWordmark: View {
    var name = "Hexorcist"
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: size * 0.35) {
            HexorcistMark()
                .frame(width: size * 1.25, height: size * 1.25)
            Text(name)
                .font(.system(size: size, weight: .semibold, design: .serif))
                .tracking(-0.2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

/// A faint hexagon lattice, used behind the app icon mark.
struct HexLattice: View {
    var cell: CGFloat = 34
    var color: Color = .white
    var lineWidth: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            context.stroke(latticePath(size: size), with: .color(color), lineWidth: lineWidth)
        }
        .accessibilityHidden(true)
    }

    private func latticePath(size: CGSize) -> Path {
        let height: CGFloat = cell
        let width: CGFloat = cell * 0.866_025_4
        let rowStep: CGFloat = height * 0.75
        let columns = Int(size.width / width) + 2
        let rows = Int(size.height / rowStep) + 2
        var path = Path()
        for row in 0..<rows {
            let offset: CGFloat = row % 2 == 0 ? 0 : width / 2
            let y: CGFloat = CGFloat(row) * rowStep - height / 2
            for column in 0..<columns {
                let x: CGFloat = CGFloat(column) * width + offset - width / 2
                path.addPath(hexagonPath(in: CGRect(x: x, y: y, width: width, height: height)))
            }
        }
        return path
    }
}
