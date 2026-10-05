import CoreGraphics
import Foundation

/// The land dots at three densities. Zoomed in, a finer grid replaces the world one, so the dots
/// keep about the size and spacing they have at world view and a country keeps its shape instead
/// of turning into a few large discs.
enum WorldDots {
    struct Level: Sendable {
        let spacing: Double
        /// Flat triples: x and y of the dot's center in canvas units, index into `WorldData.countryCodes`.
        let dots: [Float]
    }

    /// The world grid, then the finer ones from `WorldData.detailGrids`, decoded once.
    static let levels: [Level] = {
        var levels = [Level(spacing: WorldData.dotSpacing, dots: WorldData.dots.map(Float.init))]
        for grid in WorldData.detailGrids {
            guard let data = Data(base64Encoded: grid.base64), data.count == grid.count * 6 else { continue }
            var dots = [Float]()
            dots.reserveCapacity(grid.count * 3)
            data.withUnsafeBytes { raw in
                for i in 0..<grid.count {
                    let field = { (n: Int) in raw.loadUnaligned(fromByteOffset: i * 6 + n * 2, as: UInt16.self).littleEndian }
                    dots.append(Float((Double(field(0)) + 0.5) * grid.spacing))
                    dots.append(Float((Double(field(1)) + 0.5) * grid.spacing))
                    dots.append(Float(field(2)))
                }
            }
            levels.append(Level(spacing: grid.spacing, dots: dots))
        }
        return levels
    }()

    /// The finest grid whose dots are no closer on screen than the world grid's at zoom 1: the
    /// world grid below 2×, half its spacing from 2×, a quarter from 4×.
    static func level(zoom: CGFloat) -> Level {
        levels.last { WorldData.dotSpacing / $0.spacing <= Double(zoom) + 0.001 } ?? levels[0]
    }
}
