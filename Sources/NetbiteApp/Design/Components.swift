import SwiftUI

// Reusable building blocks of the Netbite / Hexorcist interface. See docs/DESIGN.md.
// Every component takes plain `String`s (the app is English only) and works in light and dark mode.

// MARK: - Status

/// The five verdicts every screen speaks in. Each has an ink, a wash and a distinct symbol, so
/// the meaning never rests on color alone.
enum StatusKind: Hashable, Sendable, CaseIterable {
    /// Safe, allowed, live, verified (sage).
    case ok
    /// Needs a look, pending, not applied (honey).
    case warning
    /// Blocked, malicious, failed (clay).
    case danger
    /// Unknown, inactive, not checked (stone).
    case neutral
    /// Informational, in progress (lavender).
    case info

    /// Text and icon color.
    var color: Color {
        switch self {
        case .ok: .hexOK
        case .warning: .hexWarning
        case .danger: .hexDanger
        case .neutral: .hexNeutral
        case .info: .hexInfo
        }
    }

    /// Pastel fill behind `color`.
    var wash: Color {
        switch self {
        case .ok: .hexOKWash
        case .warning: .hexWarningWash
        case .danger: .hexDangerWash
        case .neutral: .hexNeutralWash
        case .info: .hexInfoWash
        }
    }

    /// Default SF Symbol; each kind has a different shape.
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .neutral: "circle.dashed"
        case .info: "info.circle.fill"
        }
    }
}

/// A capsule with an icon and a short verdict: "Live", "Blocked · CN", "Notarized", "3/70".
///
///     StatusPill("Blocked", kind: .danger, systemImage: "nosign")
struct StatusPill: View {
    enum Size {
        case regular
        case small
    }

    @Environment(\.backgroundProminence) private var prominence
    let text: String
    let kind: StatusKind
    let systemImage: String?
    let showsIcon: Bool
    let size: Size

    /// - Parameters:
    ///   - systemImage: overrides the kind's default symbol.
    ///   - showsIcon: hide the icon only where space is very tight; the icon is what makes
    ///     the verdict readable without color.
    init(_ text: String, kind: StatusKind = .neutral, systemImage: String? = nil, showsIcon: Bool = true, size: Size = .regular) {
        self.text = text
        self.kind = kind
        self.systemImage = systemImage
        self.showsIcon = showsIcon
        self.size = size
    }

    var body: some View {
        // On a selected (accent-filled) row, switch to white so the pill stays readable.
        let onSelection = prominence == .increased
        let ink: Color = onSelection ? .white : kind.color
        let fill: Color = onSelection ? .white.opacity(0.18) : kind.wash
        let small = size == .small
        HStack(spacing: small ? 3 : 4) {
            if showsIcon {
                Image(systemName: systemImage ?? kind.symbol)
                    .font(.system(size: small ? 7.5 : 9, weight: .bold))
            }
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(small ? Font.caption2.weight(.semibold) : Font.caption.weight(.semibold))
        .foregroundStyle(ink)
        .padding(.horizontal, small ? 6 : 8)
        .padding(.vertical, small ? 1 : 2.5)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(ink.opacity(0.16), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A small round status light. `pulsing` adds a slow halo (skipped under Reduce Motion);
/// keep it for the one indicator that means "running right now".
///
///     StatusDot(kind: .ok, pulsing: !monitor.isPaused)
struct StatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: StatusKind
    var pulsing = false
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                PhaseAnimator([false, true]) { expanded in
                    Circle()
                        .stroke(kind.color, lineWidth: 1.5)
                        .scaleEffect(expanded ? 2.4 : 1)
                        .opacity(expanded ? 0 : 0.6)
                } animation: { expanded in
                    expanded ? Animation.easeOut(duration: 1.6) : Animation.linear(duration: 0.01)
                }
            }
            Circle().fill(kind.color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Shapes and tiles

/// A pointy-top regular hexagon, the "ward" motif of the brand, with optional rounded corners.
///
///     Hexagon(cornerRadius: 4).fill(Color.hexInfoWash)
struct Hexagon: Shape {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = 0) {
        self.cornerRadius = cornerRadius
    }

    nonisolated func path(in rect: CGRect) -> Path {
        hexagonPath(in: rect, cornerRadius: cornerRadius)
    }
}

/// The path of `Hexagon`, usable outside views (Canvas drawing, brand geometry).
func hexagonPath(in rect: CGRect, cornerRadius: CGFloat = 0) -> Path {
    let radius: CGFloat = min(rect.height / 2, rect.width / 1.732_050_8)
    let halfWidth: CGFloat = radius * 0.866_025_4
    let half: CGFloat = radius / 2
    let cx: CGFloat = rect.midX
    let cy: CGFloat = rect.midY
    let points: [CGPoint] = [
        CGPoint(x: cx, y: cy - radius),
        CGPoint(x: cx + halfWidth, y: cy - half),
        CGPoint(x: cx + halfWidth, y: cy + half),
        CGPoint(x: cx, y: cy + radius),
        CGPoint(x: cx - halfWidth, y: cy + half),
        CGPoint(x: cx - halfWidth, y: cy - half),
    ]
    var path = Path()
    if cornerRadius <= 0 {
        path.addLines(points)
        path.closeSubpath()
        return path
    }
    let first = points[0]
    let last = points[5]
    path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
    for index in 0..<6 {
        let next = points[(index + 1) % 6]
        path.addArc(tangent1End: points[index], tangent2End: next, radius: cornerRadius)
    }
    path.closeSubpath()
    return path
}

/// An SF Symbol on a soft tinted tile: hexagon (brand, navigation, headers), rounded square, or circle.
///
///     SymbolTile("nosign", tint: .hexDanger, size: 26)
struct SymbolTile: View {
    enum TileShape {
        case hexagon
        case rounded
        case circle
    }

    @Environment(\.backgroundProminence) private var prominence
    let systemImage: String
    let tint: Color
    let size: CGFloat
    let shape: TileShape

    init(_ systemImage: String, tint: Color = .hexInfo, size: CGFloat = 28, shape: TileShape = .hexagon) {
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
        self.shape = shape
    }

    var body: some View {
        let ink: Color = prominence == .increased ? .white : tint
        let symbolSize: CGFloat = shape == .hexagon ? size * 0.40 : size * 0.46
        ZStack {
            tile(ink)
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(ink)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(_ ink: Color) -> some View {
        switch shape {
        case .hexagon:
            let hexagon = Hexagon(cornerRadius: size * 0.12)
            hexagon.fill(ink.opacity(0.16)).overlay(hexagon.stroke(ink.opacity(0.32), lineWidth: 1))
        case .rounded:
            let square = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            square.fill(ink.opacity(0.16)).overlay(square.strokeBorder(ink.opacity(0.28), lineWidth: 1))
        case .circle:
            Circle().fill(ink.opacity(0.16)).overlay(Circle().strokeBorder(ink.opacity(0.28), lineWidth: 1))
        }
    }
}

/// A small monospaced tag for codes: country codes, rule kinds, PIDs, team IDs.
///
///     CodeTag("CIDR")
struct CodeTag: View {
    let text: String
    let tint: Color?

    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        let ink: Color = tint ?? .secondary
        let shape = RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(shape.fill(ink.opacity(0.08)))
            .overlay(shape.strokeBorder(ink.opacity(0.25), lineWidth: 0.5))
            .fixedSize()
    }
}

// MARK: - Containers

/// The surface of a card: raised fill, hairline border, soft shadow. Optionally tinted.
struct CardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let border: Color = tint.map { $0.opacity(0.40) } ?? .surfaceStroke
        content
            .background {
                shape
                    .fill(Color.surfaceCard)
                    .overlay { if let tint { shape.fill(tint.opacity(0.07)) } }
                    .shadow(color: .surfaceShadow, radius: 6, x: 0, y: 2)
            }
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }
}

/// The surface of a recessed well (the map plate, code blocks): no shadow.
struct InsetSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(Color.surfaceInset))
            .overlay(shape.strokeBorder(Color.surfaceStroke, lineWidth: 1))
    }
}

extension View {
    /// Draws a card behind the view without adding padding. `tint` colors the fill and border
    /// (for example `.hexDanger` for a blocked tile).
    func cardSurface(cornerRadius: CGFloat = Radius.lg, tint: Color? = nil) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, tint: tint))
    }

    /// Draws a recessed well behind the view.
    func insetSurface(cornerRadius: CGFloat = Radius.md) -> some View {
        modifier(InsetSurface(cornerRadius: cornerRadius))
    }

    /// The cream / warm charcoal canvas behind a screen. Pair it with
    /// `.scrollContentBackground(.hidden)` on lists and forms.
    func canvasBackground() -> some View {
        background(Color.surfaceCanvas)
    }
}

/// A padded card that fills the available width.
///
///     Card { SectionHeader("Details", style: .eyebrow); DetailRow("Path", value: path) }
struct Card<Content: View>: View {
    let padding: CGFloat
    let spacing: CGFloat
    let tint: Color?
    let content: Content

    init(padding: CGFloat = Spacing.lg, spacing: CGFloat = Spacing.md, tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.spacing = spacing
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(tint: tint)
    }
}

// MARK: - Headers

/// The heading of a screen: hexagon tile, serif title, subtitle, trailing actions.
///
///     ScreenHeader("Persistence", subtitle: "What starts by itself", systemImage: "arrow.triangle.2.circlepath") {
///         Button("Scan again") { … }
///     }
///
/// Put it at the top of a scrolling screen, or pass `pinned: true` to get a padded bar with a
/// bottom hairline, to place above a `List` or `Table`.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let tint: Color
    let pinned: Bool
    let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        tint: Color = .hexInfo,
        pinned: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.pinned = pinned
        self.trailing = trailing()
    }

    var body: some View {
        if pinned {
            content
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.md)
                .background(Color.surfaceCanvas)
                .overlay(alignment: .bottom) { Divider() }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            if let systemImage {
                SymbolTile(systemImage, tint: tint, size: pinned ? 34 : 44)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(pinned ? Font.sectionTitle : Font.displayTitle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(pinned ? Font.callout : Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.lg)
            HStack(spacing: Spacing.sm) {
                trailing
            }
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tint: Color = .hexInfo, pinned: Bool = false) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, tint: tint, pinned: pinned) { EmptyView() }
    }
}

/// The heading of a section: a serif title (`.title`) or a small uppercase label (`.eyebrow`,
/// for groups inside cards and inspectors), with an optional subtitle and trailing accessory.
///
///     SectionHeader("Countries", subtitle: "Block every range of a country.") { TextField(…) }
///     SectionHeader("Activity", style: .eyebrow)
struct SectionHeader<Trailing: View>: View {
    enum Style {
        case title
        case eyebrow
    }

    let title: String
    let subtitle: String?
    let systemImage: String?
    let style: Style
    let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        style: Style = .title,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.style = style
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                titleRow
                if let subtitle {
                    Text(subtitle)
                        .font(style == .title ? Font.callout : Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.md)
            trailing
        }
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            switch style {
            case .title:
                Text(title).font(.sectionTitle)
            case .eyebrow:
                Text(title)
                    .font(.eyebrow)
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
        }
        .font(style == .title ? Font.title3 : Font.caption)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, style: Style = .title) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, style: style) { EmptyView() }
    }
}

// MARK: - Rows

/// A label/value line for inspectors: secondary label in a fixed column, value on the right.
///
///     DetailRow("Team ID", value: info.teamIdentifier ?? "–", monospaced: true)
///     DetailRow("Trust") { SignatureBadge(path: path) }
struct DetailRow<Value: View>: View {
    let label: String
    let labelWidth: CGFloat
    let value: Value

    init(_ label: String, labelWidth: CGFloat = 104, @ViewBuilder value: () -> Value) {
        self.label = label
        self.labelWidth = labelWidth
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// The text value of a `DetailRow`: selectable, optionally monospaced.
struct DetailValueText: View {
    let text: String
    let monospaced: Bool

    var body: some View {
        Text(text)
            .font(monospaced ? Font.dataMonoCallout : Font.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension DetailRow where Value == DetailValueText {
    init(_ label: String, value: String, monospaced: Bool = false, labelWidth: CGFloat = 104) {
        self.init(label, labelWidth: labelWidth) { DetailValueText(text: value, monospaced: monospaced) }
    }
}

/// A big number with a caption, for summaries: "128 destinations", "3 unsigned".
///
///     Metric("\(rows.count)", label: "destinations")
struct Metric: View {
    let value: String
    let label: String
    let tint: Color

    init(_ value: String, label: String, tint: Color = .primary) {
        self.value = value
        self.label = label
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.metricValue)
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Banners and empty states

/// A calm inline message with a verdict color and optional actions. Use it for pending changes,
/// missing setup and errors; never for celebration.
///
///     Banner("2 pending changes", message: "Nothing changes until you apply.", kind: .warning) {
///         Button("Apply") { … }.buttonStyle(.borderedProminent)
///     }
struct Banner<Actions: View>: View {
    let title: String
    let message: String?
    let kind: StatusKind
    let systemImage: String?
    let actionsBelow: Bool
    let actions: Actions

    /// - Parameter actionsBelow: put the actions under the text, for narrow columns (inspectors).
    init(
        _ title: String,
        message: String? = nil,
        kind: StatusKind = .info,
        systemImage: String? = nil,
        actionsBelow: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.kind = kind
        self.systemImage = systemImage
        self.actionsBelow = actionsBelow
        self.actions = actions()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        HStack(alignment: actionsBelow ? .top : .center, spacing: Spacing.md) {
            Image(systemName: systemImage ?? kind.symbol)
                .font(.title3)
                .foregroundStyle(kind.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                text
                if actionsBelow {
                    HStack(spacing: Spacing.sm) { actions }
                }
            }
            Spacer(minLength: actionsBelow ? 0 : Spacing.md)
            if !actionsBelow {
                HStack(spacing: Spacing.sm) { actions }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(shape.fill(kind.wash))
        .overlay(shape.strokeBorder(kind.color.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title).fontWeight(.semibold)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension Banner where Actions == EmptyView {
    init(_ title: String, message: String? = nil, kind: StatusKind = .info, systemImage: String? = nil) {
        self.init(title, message: message, kind: kind, systemImage: systemImage, actionsBelow: false) { EmptyView() }
    }
}

/// A friendly placeholder for an empty list or panel: a symbol inside a dashed hexagon ward,
/// a title, a one-line message and optional actions. Fills its container unless `compact`.
///
///     EmptyStateView("Nothing lurking here", systemImage: "sparkles",
///                    message: "No launch item to review.") { Button("Scan again") { … } }
struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String?
    let tint: Color
    let compact: Bool
    let actions: Actions

    init(
        _ title: String,
        systemImage: String,
        message: String? = nil,
        tint: Color = .hexInfo,
        compact: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.tint = tint
        self.compact = compact
        self.actions = actions()
    }

    var body: some View {
        let maxHeight: CGFloat? = compact ? nil : .infinity
        VStack(spacing: compact ? Spacing.sm : Spacing.md) {
            ward
            VStack(spacing: Spacing.xs) {
                Text(title)
                    .font(compact ? Font.headline : Font.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(compact ? Font.callout : Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
            HStack(spacing: Spacing.sm) {
                actions
            }
            .padding(.top, Spacing.xs)
        }
        .padding(compact ? Spacing.lg : Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
    }

    private var ward: some View {
        let outer: CGFloat = compact ? 52 : 84
        let inner: CGFloat = compact ? 34 : 54
        return ZStack {
            Hexagon(cornerRadius: outer * 0.1)
                .stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 4]))
                .rotationEffect(.degrees(30))
                .frame(width: outer, height: outer)
            SymbolTile(systemImage, tint: tint, size: inner)
        }
        .accessibilityHidden(true)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(_ title: String, systemImage: String, message: String? = nil, tint: Color = .hexInfo, compact: Bool = false) {
        self.init(title, systemImage: systemImage, message: message, tint: tint, compact: compact) { EmptyView() }
    }
}

// MARK: - Navigation

/// A sidebar entry for a screen: hexagon tile, title, one-line subtitle, optional trailing
/// accessory (a count, a sparkline). Tag it as usual.
///
///     SidebarLabel("Persistence", subtitle: "124 items · 3 to review",
///                  systemImage: "arrow.triangle.2.circlepath").tag(SidebarItem.persistence)
struct SidebarLabel<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    let accessory: Accessory

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = .hexInfo,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            SymbolTile(systemImage, tint: tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.xs)
            accessory
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

extension SidebarLabel where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String, tint: Color = .hexInfo) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}
