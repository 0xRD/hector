import CoreGraphics
import NetbiteCore

/// Equirectangular projection of the world onto the map rectangle, and the arcs drawn on it.
struct MapGeometry {
    static let aspectRatio = WorldData.canvasWidth / WorldData.canvasHeight

    /// The map rectangle inside the view, letterboxed to keep the aspect ratio.
    let rect: CGRect

    init(size: CGSize) {
        let width = min(size.width, size.height * Self.aspectRatio)
        let height = width / Self.aspectRatio
        rect = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    var scale: CGFloat { rect.width / WorldData.canvasWidth }

    func point(canvasX x: Double, y: Double) -> CGPoint {
        CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }

    func point(longitude: Double, latitude: Double) -> CGPoint {
        point(canvasX: (longitude + 180) / 360 * WorldData.canvasWidth,
              y: (WorldData.topLatitude - latitude) / WorldData.latitudeSpan * WorldData.canvasHeight)
    }

    /// Label point of a country, or `nil` when the map does not know it.
    func point(country: String) -> CGPoint? {
        guard let index = WorldData.countryIndex[country] else { return nil }
        return point(longitude: WorldData.labelPoints[index * 2], latitude: WorldData.labelPoints[index * 2 + 1])
    }

    /// Where the line to `address` ends: its country, nudged by a stable offset derived from the
    /// address so that several destinations in one country fan out instead of overlapping.
    func endpoint(country: String, address: IPAddress) -> CGPoint? {
        guard let center = point(country: country) else { return nil }
        let hash = Self.fnv1a(address.description)
        let angle = Double(hash % 360) * .pi / 180
        let radius = (0.35 + Double((hash >> 9) % 100) / 100 * 0.65) * 9 * scale
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    /// A quadratic arc bowing upward, like a flight path.
    func arc(from start: CGPoint, to end: CGPoint) -> Arc {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - distance * 0.22)
        return Arc(start: start, control: control, end: end)
    }

    struct Arc {
        let start: CGPoint
        let control: CGPoint
        let end: CGPoint

        var path: CGPath {
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
            return path
        }

        /// Points along the arc for hit-testing; the first fifth is skipped because every arc
        /// starts at the same origin.
        func samples(_ count: Int = 18) -> [CGPoint] {
            (0...count).map { i in
                let t = 0.2 + 0.8 * Double(i) / Double(count)
                let u = 1 - t
                return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                               y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
            }
        }
    }

    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }
}

extension WorldData {
    static let countryIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: countryCodes.enumerated().map { ($1, $0) }
    )
}
