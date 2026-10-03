import SwiftUI

/// Dot-matrix world map with one arc per destination, from the user's country to the destination's.
///
/// Hovering an arc highlights it, dims other apps' arcs and reports the destination through
/// `hovered`, which the sidebar and the list use to highlight the owning app and row.
struct WorldMapView: View {
    let rows: [DestinationRow]
    /// App whose arcs stay emphasized when nothing is hovered (`nil`: all apps).
    let focusAppID: AppGroup.ID?
    let originCountry: String
    let selected: DestinationRef?
    @Binding var hovered: DestinationRef?
    let onSelect: (DestinationRow) -> Void

    private struct PlacedArc {
        let row: DestinationRow
        let arc: MapGeometry.Arc
        let samples: [CGPoint]
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = MapGeometry(size: proxy.size)
            let arcs = placedArcs(geometry)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    draw(in: &context, geometry: geometry, arcs: arcs)
                }
                if let hovered, let item = arcs.first(where: { $0.row.id == hovered }) {
                    // To the right of the endpoint, or to its left near the right edge.
                    let fitsRight = item.arc.end.x + 14 + MapTooltip.width <= proxy.size.width
                    let centerX = fitsRight ? item.arc.end.x + 14 + MapTooltip.width / 2 : item.arc.end.x - 14 - MapTooltip.width / 2
                    MapTooltip(row: item.row)
                        .position(x: centerX, y: min(max(item.arc.end.y, 55), proxy.size.height - 55))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let nearest = nearestArc(to: location, in: arcs)?.row.id
                    if nearest != hovered { hovered = nearest }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture {
                if let hovered, let item = arcs.first(where: { $0.row.id == hovered }) {
                    onSelect(item.row)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("World map of \(rows.count) destinations")
    }

    // MARK: - Layout

    private func placedArcs(_ geometry: MapGeometry) -> [PlacedArc] {
        guard let origin = geometry.point(country: originCountry) else { return [] }
        return rows.compactMap { row in
            guard let country = row.destination.country,
                  let end = geometry.endpoint(country: country, address: row.destination.key.address) else { return nil }
            let arc = geometry.arc(from: origin, to: end)
            return PlacedArc(row: row, arc: arc, samples: arc.samples())
        }
    }

    private func nearestArc(to location: CGPoint, in arcs: [PlacedArc]) -> PlacedArc? {
        var best: PlacedArc?
        var bestDistance: CGFloat = 9
        for arc in arcs {
            for sample in arc.samples {
                let distance = hypot(sample.x - location.x, sample.y - location.y)
                if distance < bestDistance {
                    bestDistance = distance
                    best = arc
                }
            }
        }
        return best
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, geometry: MapGeometry, arcs: [PlacedArc]) {
        let contacted = Set(rows.compactMap { $0.destination.country }.compactMap { WorldData.countryIndex[$0] })
        let radius = WorldData.dotSpacing * geometry.scale * 0.21
        var land = Path()
        var landContacted = Path()
        let dots = WorldData.dots
        for i in stride(from: 0, to: dots.count, by: 3) {
            let center = geometry.point(canvasX: Double(dots[i]), y: Double(dots[i + 1]))
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            if contacted.contains(Int(dots[i + 2])) {
                landContacted.addEllipse(in: rect)
            } else {
                land.addEllipse(in: rect)
            }
        }
        context.fill(land, with: .color(.mapLand))
        context.fill(landContacted, with: .color(.mapLandContacted))

        let focus = hovered?.appID ?? focusAppID
        let hot = hovered ?? selected
        let dashed = StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 4])

        // Dimmed arcs first, emphasized ones on top, the hovered or selected one last.
        for item in arcs where focus != nil && item.row.app.id != focus {
            let style = item.row.destination.isLive ? StrokeStyle(lineWidth: 1) : StrokeStyle(lineWidth: 1, dash: [4, 4])
            context.stroke(Path(item.arc.path), with: .color(.netbiteAccent.opacity(0.12)), style: style)
        }
        for item in arcs where focus == nil || item.row.app.id == focus {
            let live = item.row.destination.isLive
            context.stroke(Path(item.arc.path), with: .color(.netbiteAccent.opacity(live ? 0.6 : 0.4)),
                           style: live ? StrokeStyle(lineWidth: 1.5) : dashed)
        }
        for item in arcs {
            let emphasized = focus == nil || item.row.app.id == focus
            let size: CGFloat = emphasized ? 6 : 4
            let dot = CGRect(x: item.arc.end.x - size / 2, y: item.arc.end.y - size / 2, width: size, height: size)
            let color: Color = item.row.destination.isLive ? .netbiteAccent : .secondary
            context.fill(Path(ellipseIn: dot), with: .color(color.opacity(emphasized ? 1 : 0.35)))
        }
        if let hot, let item = arcs.first(where: { $0.row.id == hot }) {
            context.stroke(Path(item.arc.path), with: .color(.netbiteAccent), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            let ring = CGRect(x: item.arc.end.x - 8, y: item.arc.end.y - 8, width: 16, height: 16)
            context.stroke(Path(ellipseIn: ring), with: .color(.netbiteAccent), lineWidth: 2)
        }

        if let origin = geometry.point(country: originCountry) {
            context.fill(Path(ellipseIn: CGRect(x: origin.x - 4.5, y: origin.y - 4.5, width: 9, height: 9)), with: .color(.primary))
            context.stroke(Path(ellipseIn: CGRect(x: origin.x - 10, y: origin.y - 10, width: 20, height: 20)),
                           with: .color(.primary.opacity(0.35)), lineWidth: 1)
        }
    }
}

/// What the map shows next to the hovered line: the process first, then the destination.
struct MapTooltip: View {
    static let width: CGFloat = 240
    let row: DestinationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                AppIcon(app: row.app, size: 20)
                Text(row.app.name).font(.headline).lineLimit(1)
            }
            Text(row.destination.title)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(Countries.name(row.destination.country)) · \(row.destination.key.portLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if row.destination.isLive {
                Text(row.destination.liveConnections > 1 ? "Live · \(row.destination.liveConnections) connections" : "Live · 1 connection")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.netbiteAccent)
            } else {
                Text("Last seen \(row.destination.lastSeen, format: .relative(presentation: .named))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
