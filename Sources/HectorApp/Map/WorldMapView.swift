import HectorCore
import SwiftUI

/// Dot-matrix world map, zoomable, with lines from the user's country to the destinations.
///
/// At world scale there is one line per country, thicker for more destinations, ending in a
/// bubble with their count: hovering it lists the apps, clicking it filters the screen to that
/// country. Zoomed in (`MapViewport.detailZoom`), or with a country filter, each destination
/// gets its own line again; hovering one reports it through `WindowState.hovered`, which the
/// sidebar and the list use to highlight the owning app and row.
///
/// Pinch to zoom, drag to pan; the buttons zoom in and out, fit what is shown, or show the world
/// (⌘=, ⌘-, ⌘9 and ⌘0 while the map is on screen).
struct WorldMapView: View {
    let rows: [DestinationRow]
    /// App whose lines stay emphasized when nothing is hovered (`nil`: all apps).
    let focusAppID: AppGroup.ID?
    let originCountry: String
    /// Passed in rather than read from the environment, like the list rows, and written directly.
    let state: WindowState
    let onSelect: (DestinationRow) -> Void

    private struct PlacedArc {
        let row: DestinationRow
        let arc: MapGeometry.Arc
        let samples: [CGPoint]
    }

    /// Every destination of one country, drawn as one line.
    private struct CountryNode {
        let country: String
        let rows: [DestinationRow]
        let arc: MapGeometry.Arc
        let samples: [CGPoint]

        var isLive: Bool { rows.contains { $0.destination.isLive } }
        var isAllBlocked: Bool { rows.allSatisfy(\.isBlocked) }
        var lineWidth: CGFloat { min(1.5 + log2(CGFloat(rows.count)) * 1.1, 6) }
        var bubbleRadius: CGFloat { rows.count == 1 ? 4 : 7 + min(log2(CGFloat(rows.count)) * 1.5, 7) }
        func contains(app: AppGroup.ID) -> Bool { rows.contains { $0.app.id == app } }
    }

    private var showsDestinations: Bool { state.countryFilter != nil || state.mapViewport.showsDestinations }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let geometry = MapGeometry(size: size, viewport: state.mapViewport)
            let detailed = showsDestinations
            let arcs = detailed ? placedArcs(geometry) : []
            let nodes = detailed ? [] : countryNodes(geometry)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawLand(in: &context, geometry: geometry)
                    if detailed {
                        drawDestinations(in: &context, arcs: arcs)
                    } else {
                        drawCountries(in: &context, nodes: nodes)
                    }
                    drawOrigin(in: &context, geometry: geometry)
                }
                tooltip(arcs: arcs, nodes: nodes, size: size)
                controls(size: size, geometry: geometry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(Spacing.sm)
            }
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if detailed {
                        let nearest = nearestArc(to: location, in: arcs)?.row.id
                        if nearest != state.hovered { state.hovered = nearest }
                    } else {
                        let nearest = nearestNode(to: location, in: nodes)?.country
                        if nearest != state.hoveredCountry { state.hoveredCountry = nearest }
                    }
                case .ended:
                    // Only when something was hovered: every write re-renders the window, lists included.
                    if state.hovered != nil { state.hovered = nil }
                    if state.hoveredCountry != nil { state.hoveredCountry = nil }
                }
            }
            .onTapGesture {
                if detailed {
                    if let hovered = state.hovered, let item = arcs.first(where: { $0.row.id == hovered }) { onSelect(item.row) }
                } else if let country = state.hoveredCountry {
                    state.hoveredCountry = nil
                    state.countryFilter = country
                }
            }
            .gesture(magnify(size: size))
            .simultaneousGesture(pan(size: size))
            .task(id: state.countryFilter) {
                // A new country filter frames that country; clearing it shows the world again.
                guard let country = state.countryFilter else {
                    state.mapViewport = .world
                    return
                }
                let points = rows.filter { $0.destination.country == country }.compactMap(canvasEndpoint)
                state.mapViewport = MapViewport.fitting(points, in: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("World map of \(rows.count) destinations")
    }

    // MARK: - Layout

    private func canvasEndpoint(_ row: DestinationRow) -> CGPoint? {
        guard let country = row.destination.country else { return nil }
        return MapGeometry.canvasEndpoint(country: country, address: row.destination.key.address)
    }

    private func placedArcs(_ geometry: MapGeometry) -> [PlacedArc] {
        guard let origin = geometry.point(country: originCountry) else { return [] }
        return rows.compactMap { row in
            guard let country = row.destination.country,
                  let end = geometry.endpoint(country: country, address: row.destination.key.address) else { return nil }
            let arc = geometry.arc(from: origin, to: end)
            return PlacedArc(row: row, arc: arc, samples: arc.samples())
        }
    }

    private func countryNodes(_ geometry: MapGeometry) -> [CountryNode] {
        guard let origin = geometry.point(country: originCountry) else { return [] }
        var order: [String] = []
        var byCountry: [String: [DestinationRow]] = [:]
        for row in rows {
            guard let country = row.destination.country, WorldData.countryIndex[country] != nil else { continue }
            if byCountry[country] == nil { order.append(country) }
            byCountry[country, default: []].append(row)
        }
        return order.compactMap { country in
            guard var end = geometry.point(country: country) else { return nil }
            // The user's own country would sit under the "You" dot: set its bubble beside it.
            if country == originCountry { end = CGPoint(x: origin.x + 22, y: origin.y + 16) }
            let arc = geometry.arc(from: origin, to: end)
            return CountryNode(country: country, rows: byCountry[country]!, arc: arc, samples: arc.samples())
        }
        // Small countries last, so their bubbles stay on top of big ones.
        .sorted { $0.rows.count > $1.rows.count }
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

    /// The bubble under the pointer first, else the nearest line.
    private func nearestNode(to location: CGPoint, in nodes: [CountryNode]) -> CountryNode? {
        if let bubble = nodes.reversed().first(where: { hypot($0.arc.end.x - location.x, $0.arc.end.y - location.y) <= $0.bubbleRadius + 4 }) {
            return bubble
        }
        var best: CountryNode?
        var bestDistance: CGFloat = 9
        for node in nodes {
            for sample in node.samples {
                let distance = hypot(sample.x - location.x, sample.y - location.y)
                if distance < bestDistance {
                    bestDistance = distance
                    best = node
                }
            }
        }
        return best
    }

    // MARK: - Zoom and pan

    private func magnify(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = state.mapGestureStart ?? state.mapViewport
                state.mapGestureStart = start
                // The canvas point under the fingers stays under them.
                let anchor = MapGeometry(size: size, viewport: start).canvasPoint(value.startLocation)
                var next = start
                next.zoom = min(max(start.zoom * value.magnification, 1), MapViewport.maximumZoom)
                let scale = MapGeometry.fitScale(size) * next.zoom
                next.center = CGPoint(x: anchor.x - (value.startLocation.x - size.width / 2) / scale,
                                      y: anchor.y - (value.startLocation.y - size.height / 2) / scale)
                state.mapViewport = next.clamped(to: size)
            }
            .onEnded { _ in state.mapGestureStart = nil }
    }

    private func pan(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = state.mapGestureStart ?? state.mapViewport
                state.mapGestureStart = start
                let scale = MapGeometry.fitScale(size) * start.zoom
                var next = start
                next.center = CGPoint(x: start.center.x - value.translation.width / scale,
                                      y: start.center.y - value.translation.height / scale)
                state.mapViewport = next.clamped(to: size)
            }
            .onEnded { _ in state.mapGestureStart = nil }
    }

    private func zoom(by factor: CGFloat, size: CGSize) {
        var next = state.mapViewport
        next.zoom *= factor
        state.mapViewport = next.clamped(to: size)
    }

    /// Frames every destination shown and this Mac.
    private func fit(size: CGSize) {
        var points = rows.compactMap(canvasEndpoint)
        if let origin = MapGeometry.canvasPoint(country: originCountry) { points.append(origin) }
        state.mapViewport = MapViewport.fitting(points, in: size)
    }

    private func controls(size: CGSize, geometry: MapGeometry) -> some View {
        let viewport = state.mapViewport
        return VStack(spacing: 2) {
            MapControlButton("plus", help: "Zoom in", shortcut: KeyboardShortcut("=", modifiers: .command)) {
                zoom(by: 1.6, size: size)
            }
            .disabled(viewport.zoom >= MapViewport.maximumZoom)
            MapControlButton("minus", help: "Zoom out", shortcut: KeyboardShortcut("-", modifiers: .command)) {
                zoom(by: 1 / 1.6, size: size)
            }
            .disabled(viewport.zoom <= 1)
            Divider().frame(width: 18)
            MapControlButton("scope", help: "Fit the destinations shown", shortcut: KeyboardShortcut("9", modifiers: .command)) {
                fit(size: size)
            }
            MapControlButton("globe", help: "Show the whole world", shortcut: KeyboardShortcut("0", modifiers: .command)) {
                state.mapViewport = .world
            }
            .disabled(viewport == .world)
        }
        .padding(4)
        .cardSurface(cornerRadius: Radius.md)
    }

    // MARK: - Drawing

    private func drawLand(in context: inout GraphicsContext, geometry: MapGeometry) {
        let contacted = Set(rows.compactMap { $0.destination.country }.compactMap { WorldData.countryIndex[$0] })
        let paths = LandPaths.shared.paths(for: geometry, contacted: contacted)
        context.fill(paths.land, with: .color(.mapLand))
        context.fill(paths.contacted, with: .color(.mapLandContacted))
    }

    private func drawOrigin(in context: inout GraphicsContext, geometry: MapGeometry) {
        guard let origin = geometry.point(country: originCountry) else { return }
        context.fill(Path(ellipseIn: CGRect(x: origin.x - 4.5, y: origin.y - 4.5, width: 9, height: 9)), with: .color(.primary))
        context.stroke(Path(ellipseIn: CGRect(x: origin.x - 10, y: origin.y - 10, width: 20, height: 20)),
                       with: .color(.primary.opacity(0.35)), lineWidth: 1)
    }

    private func dimmedOpacity(_ context: GraphicsContext) -> Double {
        // Deep inks on the cream plate need a little more opacity than pastel inks on charcoal.
        context.environment.colorScheme == .light ? 0.2 : 0.12
    }

    private func drawCountries(in context: inout GraphicsContext, nodes: [CountryNode]) {
        let focus = state.hovered?.appID ?? focusAppID
        // The hovered bubble, else the country of the row hovered or selected in the list.
        let hotRef = state.hovered ?? state.selectedDestination
        let hot = state.hoveredCountry ?? hotRef.flatMap { ref in
            nodes.first { node in node.rows.contains { $0.id == ref } }?.country
        }
        let dimmed = dimmedOpacity(context)

        for node in nodes {
            let emphasized = focus.map(node.contains(app:)) ?? true
            let color: Color = node.isAllBlocked ? .hectorDanger : .hectorOK
            let dashed = node.isAllBlocked || !node.isLive
            let style = StrokeStyle(lineWidth: emphasized ? node.lineWidth : 1, lineCap: .round, dash: dashed ? [4, 4] : [])
            let opacity = emphasized ? (node.isLive || node.isAllBlocked ? 0.65 : 0.4) : dimmed
            if node.country == hot {
                context.stroke(Path(node.arc.path), with: .color(color.opacity(0.18)),
                               style: StrokeStyle(lineWidth: node.lineWidth + 8, lineCap: .round))
            }
            context.stroke(Path(node.arc.path), with: .color(color.opacity(node.country == hot ? 1 : opacity)), style: style)
        }
        for node in nodes {
            let emphasized = focus.map(node.contains(app:)) ?? true
            let fill: Color = node.isAllBlocked ? .hectorDanger : (node.isLive ? .hectorOK : .secondary)
            let r = node.bubbleRadius
            let bubble = CGRect(x: node.arc.end.x - r, y: node.arc.end.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: bubble), with: .color(fill.opacity(emphasized ? 1 : 0.35)))
            if node.country == hot {
                context.stroke(Path(ellipseIn: bubble.insetBy(dx: -3, dy: -3)), with: .color(fill), lineWidth: 2)
            }
            if node.rows.count > 1 {
                let label = Text("\(node.rows.count)").font(.system(size: r > 10 ? 10 : 9, weight: .bold)).monospacedDigit()
                    .foregroundColor(Color.surfaceCanvas)
                context.draw(label, at: node.arc.end)
            }
        }
    }

    private func drawDestinations(in context: inout GraphicsContext, arcs: [PlacedArc]) {
        let focus = state.hovered?.appID ?? focusAppID
        let hot = state.hovered ?? state.selectedDestination

        // Dimmed arcs first, emphasized ones on top, the hovered or selected one last.
        // Blocked destinations are red and dashed; recent ones dashed; live ones solid.
        func color(_ row: DestinationRow) -> Color { row.isBlocked ? .hectorDanger : .hectorOK }
        func style(_ row: DestinationRow, width: CGFloat) -> StrokeStyle {
            row.isBlocked || !row.destination.isLive ? StrokeStyle(lineWidth: width, lineCap: .round, dash: [4, 4]) : StrokeStyle(lineWidth: width)
        }
        let dimmed = dimmedOpacity(context)
        for item in arcs where focus != nil && item.row.app.id != focus {
            context.stroke(Path(item.arc.path), with: .color(color(item.row).opacity(dimmed)), style: style(item.row, width: 1))
        }
        for item in arcs where focus == nil || item.row.app.id == focus {
            let strong = item.row.destination.isLive || item.row.isBlocked
            context.stroke(Path(item.arc.path), with: .color(color(item.row).opacity(strong ? 0.65 : 0.4)), style: style(item.row, width: 1.5))
        }
        for item in arcs {
            let emphasized = focus == nil || item.row.app.id == focus
            let size: CGFloat = emphasized ? 6 : 4
            let dot = CGRect(x: item.arc.end.x - size / 2, y: item.arc.end.y - size / 2, width: size, height: size)
            let fill: Color = item.row.isBlocked ? .hectorDanger : (item.row.destination.isLive ? .hectorOK : .secondary)
            context.fill(Path(ellipseIn: dot), with: .color(fill.opacity(emphasized ? 1 : 0.35)))
        }
        if let hot, let item = arcs.first(where: { $0.row.id == hot }) {
            // A soft halo under the hovered or selected line.
            context.stroke(Path(item.arc.path), with: .color(color(item.row).opacity(0.18)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
            context.stroke(Path(item.arc.path), with: .color(color(item.row)), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            let ring = CGRect(x: item.arc.end.x - 8, y: item.arc.end.y - 8, width: 16, height: 16)
            context.stroke(Path(ellipseIn: ring), with: .color(color(item.row)), lineWidth: 2)
        }
    }

    // MARK: - Tooltip

    @ViewBuilder
    private func tooltip(arcs: [PlacedArc], nodes: [CountryNode], size: CGSize) -> some View {
        if let hovered = state.hovered, let item = arcs.first(where: { $0.row.id == hovered }) {
            placed(MapTooltip(row: item.row), at: item.arc.end, size: size)
        } else if let country = state.hoveredCountry, let node = nodes.first(where: { $0.country == country }) {
            placed(CountryTooltip(country: country, rows: node.rows), at: node.arc.end, size: size)
        }
    }

    /// To the right of the endpoint, or to its left near the right edge.
    private func placed(_ content: some View, at point: CGPoint, size: CGSize) -> some View {
        let width = MapTooltip.width
        let fitsRight = point.x + 14 + width <= size.width
        let centerX = fitsRight ? point.x + 14 + width / 2 : point.x - 14 - width / 2
        return content
            .position(x: centerX, y: min(max(point.y, 70), size.height - 70))
            .allowsHitTesting(false)
    }
}

/// The land dots as two paths (plain and contacted countries), rebuilt only when the size, the
/// viewport or the set of contacted countries changes: about 5,000 dots, and the map redraws every
/// second while connections come and go.
private final class LandPaths: @unchecked Sendable {
    static let shared = LandPaths()

    private struct Key: Equatable {
        let rect: CGRect
        let size: CGSize
        let contacted: Set<Int>
    }

    private let lock = NSLock()
    private var key: Key?
    private var cached = (land: Path(), contacted: Path())

    func paths(for geometry: MapGeometry, contacted: Set<Int>) -> (land: Path, contacted: Path) {
        let key = Key(rect: geometry.rect, size: geometry.size, contacted: contacted)
        return lock.withLock {
            if key != self.key {
                cached = Self.build(geometry, contacted: contacted)
                self.key = key
            }
            return cached
        }
    }

    private static func build(_ geometry: MapGeometry, contacted: Set<Int>) -> (land: Path, contacted: Path) {
        // Dots grow with the zoom, so the land keeps its shape.
        let radius = WorldData.dotSpacing * geometry.scale * 0.21
        let visible = CGRect(origin: .zero, size: geometry.size).insetBy(dx: -radius, dy: -radius)
        var land = Path()
        var landContacted = Path()
        let dots = WorldData.dots
        for i in stride(from: 0, to: dots.count, by: 3) {
            let center = geometry.point(canvasX: Double(dots[i]), y: Double(dots[i + 1]))
            guard visible.contains(center) else { continue }
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            if contacted.contains(Int(dots[i + 2])) {
                landContacted.addEllipse(in: rect)
            } else {
                land.addEllipse(in: rect)
            }
        }
        return (land, landContacted)
    }
}

private struct MapControlButton: View {
    let symbol: String
    let help: String
    let shortcut: KeyboardShortcut
    let action: () -> Void

    init(_ symbol: String, help: String, shortcut: KeyboardShortcut, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.shortcut = shortcut
        self.action = action
    }

    /// "Zoom in (⌘=)": the shortcut is only discoverable through the tooltip.
    private var helpWithShortcut: String {
        "\(help) (⌘\(shortcut.key.character))"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(shortcut)
        .help(helpWithShortcut)
        .accessibilityLabel(help)
    }
}

/// Next to a country's bubble: how many destinations, and which apps reach them.
struct CountryTooltip: View {
    let country: String
    let rows: [DestinationRow]

    var body: some View {
        let apps = appCounts
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(country).font(.caption.weight(.bold).monospaced()).foregroundStyle(.secondary)
                Text(Countries.name(country)).font(.headline).lineLimit(1)
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
            ForEach(apps.prefix(4), id: \.app.id) { entry in
                HStack(spacing: 6) {
                    AppIcon(app: entry.app, size: 16)
                    Text(entry.app.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(entry.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if apps.count > 4 {
                Text("and \(apps.count - 4) more apps").font(.caption).foregroundStyle(.secondary)
            }
            Text("Click to show only this country").font(.caption.weight(.semibold)).foregroundStyle(Color.hectorOK)
        }
        .padding(Spacing.md)
        .frame(width: MapTooltip.width, alignment: .leading)
        .cardSurface(cornerRadius: Radius.md)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private var summary: String {
        let live = rows.filter(\.destination.isLive).count
        let blocked = rows.filter(\.isBlocked).count
        var parts = [rows.count == 1 ? "1 destination" : "\(rows.count) destinations"]
        if live > 0 { parts.append("\(live) live") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " · ")
    }

    private var appCounts: [(app: AppGroup, count: Int)] {
        var order: [AppGroup.ID] = []
        var byApp: [AppGroup.ID: (app: AppGroup, count: Int)] = [:]
        for row in rows {
            if byApp[row.app.id] == nil { order.append(row.app.id); byApp[row.app.id] = (row.app, 0) }
            byApp[row.app.id]!.count += 1
        }
        return order.compactMap { byApp[$0] }.sorted { $0.count > $1.count }
    }
}

/// What the map shows next to the hovered line: the process first, then the destination.
struct MapTooltip: View {
    static let width: CGFloat = 240
    let row: DestinationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AppIcon(app: row.app, size: 20)
                Text(row.app.name).font(.headline).lineLimit(1)
            }
            Text(row.destination.title)
                .font(.dataMonoCallout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(Countries.name(row.destination.country)) · \(row.destination.portsLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let network = row.destination.network {
                Text(network.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            status
        }
        .padding(Spacing.md)
        .frame(width: Self.width, alignment: .leading)
        .cardSurface(cornerRadius: Radius.md)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    @ViewBuilder
    private var status: some View {
        if let reason = row.blockReason {
            StatusPill("\(reason.label) by pf", kind: .danger, systemImage: "nosign")
        } else if row.destination.isLive {
            let count = row.destination.liveConnections
            StatusPill(count > 1 ? "Live · \(count) connections" : "Live · 1 connection", kind: .ok, systemImage: "circle.fill")
        } else {
            Text("Last seen \(row.destination.lastSeen, format: .relative(presentation: .named))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
