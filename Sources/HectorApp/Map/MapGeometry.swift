import CoreGraphics
import HectorCore

/// Which part of the world the map shows: a zoom factor and the point at the center, in the
/// map's canvas units (`WorldData.canvasWidth` × `canvasHeight`, origin at the top left).
struct MapViewport: Equatable {
    /// The land is a grid of dots about 3.6° apart: closer than this shows nothing more.
    static let maximumZoom: CGFloat = 6
    /// From this zoom on, each destination gets its own line instead of one line per country.
    static let detailZoom: CGFloat = 3
    static let world = MapViewport()

    var zoom: CGFloat = 1
    var center = CGPoint(x: WorldData.canvasWidth / 2, y: WorldData.canvasHeight / 2)

    var showsDestinations: Bool { zoom >= Self.detailZoom }

    /// Kept inside the world: no zooming out past the whole map, no panning off its edges.
    func clamped(to size: CGSize) -> MapViewport {
        var result = self
        result.zoom = min(max(zoom, 1), Self.maximumZoom)
        let scale = MapGeometry.fitScale(size) * result.zoom
        guard scale > 0 else { return .world }
        func clamp(_ value: CGFloat, extent: CGFloat, visible: CGFloat) -> CGFloat {
            let half = visible / scale / 2
            return extent <= visible / scale ? extent / 2 : min(max(value, half), extent - half)
        }
        result.center.x = clamp(center.x, extent: WorldData.canvasWidth, visible: size.width)
        result.center.y = clamp(center.y, extent: WorldData.canvasHeight, visible: size.height)
        return result
    }

    /// The smallest view that holds every point (canvas units) with a margin, zoomed no further
    /// than `maximumZoom` (one point alone gives a regional view rather than a single dot).
    static func fitting(_ points: [CGPoint], in size: CGSize, maximumZoom: CGFloat = 4) -> MapViewport {
        guard let first = points.first else { return .world }
        var box = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() { box = box.union(CGRect(origin: point, size: .zero)) }
        box = box.insetBy(dx: -40, dy: -30)
        let base = MapGeometry.fitScale(size)
        guard base > 0 else { return .world }
        let zoom = min(size.width / (box.width * base), size.height / (box.height * base), maximumZoom)
        return MapViewport(zoom: zoom, center: CGPoint(x: box.midX, y: box.midY)).clamped(to: size)
    }
}

/// Equirectangular projection of the world onto the view, through the viewport, and the arcs drawn
/// on it.
struct MapGeometry {
    static let aspectRatio = WorldData.canvasWidth / WorldData.canvasHeight

    /// The whole map in view coordinates (larger than the view when zoomed in).
    let rect: CGRect
    let size: CGSize

    /// View points per canvas unit with the whole world letterboxed in `size`.
    static func fitScale(_ size: CGSize) -> CGFloat {
        min(size.width, size.height * aspectRatio) / WorldData.canvasWidth
    }

    init(size: CGSize, viewport: MapViewport = .world) {
        self.size = size
        let viewport = viewport.clamped(to: size)
        let scale = Self.fitScale(size) * viewport.zoom
        rect = CGRect(x: size.width / 2 - viewport.center.x * scale, y: size.height / 2 - viewport.center.y * scale,
                      width: WorldData.canvasWidth * scale, height: WorldData.canvasHeight * scale)
    }

    var scale: CGFloat { rect.width / WorldData.canvasWidth }

    func point(canvasX x: Double, y: Double) -> CGPoint {
        CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }

    func point(_ canvas: CGPoint) -> CGPoint { point(canvasX: canvas.x, y: canvas.y) }

    /// The canvas point under a point of the view.
    func canvasPoint(_ view: CGPoint) -> CGPoint {
        CGPoint(x: (view.x - rect.minX) / scale, y: (view.y - rect.minY) / scale)
    }

    static func canvasPoint(longitude: Double, latitude: Double) -> CGPoint {
        CGPoint(x: (longitude + 180) / 360 * WorldData.canvasWidth,
                y: (WorldData.topLatitude - latitude) / WorldData.latitudeSpan * WorldData.canvasHeight)
    }

    /// Label point of a country in canvas units, or `nil` when the map does not know it.
    static func canvasPoint(country: String) -> CGPoint? {
        guard let index = WorldData.countryIndex[country] else { return nil }
        return canvasPoint(longitude: WorldData.labelPoints[index * 2], latitude: WorldData.labelPoints[index * 2 + 1])
    }

    /// How far from its country's label point a destination's line may end, in canvas units.
    static let endpointSpread: CGFloat = 9

    /// Where the line to `address` ends, in canvas units: its country, nudged by a stable offset
    /// derived from the address so that several destinations in one country fan out.
    static func canvasEndpoint(country: String, address: IPAddress) -> CGPoint? {
        guard let center = canvasPoint(country: country) else { return nil }
        let hash = fnv1a(address.description)
        let angle = Double(hash % 360) * .pi / 180
        let radius = (0.35 + Double((hash >> 9) % 100) / 100 * 0.65) * endpointSpread
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    func point(country: String) -> CGPoint? { Self.canvasPoint(country: country).map(point) }

    func endpoint(country: String, address: IPAddress) -> CGPoint? {
        Self.canvasEndpoint(country: country, address: address).map(point)
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
            // Typed step by step: as one expression, Swift 6.1 (Xcode 16) gives up type-checking it.
            (0...count).map { (i: Int) -> CGPoint in
                let t: CGFloat = 0.2 + 0.8 * CGFloat(i) / CGFloat(count)
                let u: CGFloat = 1 - t
                let a: CGFloat = u * u
                let b: CGFloat = 2 * u * t
                let c: CGFloat = t * t
                let x: CGFloat = a * start.x + b * control.x + c * end.x
                let y: CGFloat = a * start.y + b * control.y + c * end.y
                return CGPoint(x: x, y: y)
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
