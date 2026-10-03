import AppKit
import SwiftUI

// Design tokens of Hexorcist (the app is still called Netbite until the rename; Netbite stays
// the name of its network module). See docs/DESIGN.md for the rationale.
//
// Colors come in three grades:
// - **ink**: text and icons. Deep in light mode, soft pastel in dark mode; every ink passes
//   WCAG AA (4.5:1) on the canvas, on cards and on its own wash.
// - **wash**: pastel fills behind an ink (pills, banners, selected tiles).
// - **tint**: control fills that carry a white label (prominent buttons, switches).

// MARK: - Colors

extension Color {
    // MARK: Status inks (text-grade)

    /// Sage. Safe, allowed, live, verified.
    static let hexOK = dynamic(light: (0.24, 0.44, 0.33), dark: (0.55, 0.78, 0.62))
    /// Clay. Blocked, dangerous, destructive.
    static let hexDanger = dynamic(light: (0.66, 0.26, 0.19), dark: (0.95, 0.60, 0.52))
    /// Honey. Needs attention, pending, not applied.
    static let hexWarning = dynamic(light: (0.53, 0.37, 0.05), dark: (0.92, 0.77, 0.46))
    /// Lavender. Information, and the brand color of Hexorcist.
    static let hexInfo = dynamic(light: (0.41, 0.33, 0.64), dark: (0.76, 0.70, 0.95))
    /// Stone. Unknown, inactive, not checked yet.
    static let hexNeutral = dynamic(light: (0.42, 0.40, 0.37), dark: (0.70, 0.67, 0.63))

    /// Legacy name of `hexOK`, kept until the Hexorcist rename.
    static var netbiteAccent: Color { .hexOK }
    /// Legacy name of `hexDanger`, kept until the Hexorcist rename.
    static var netbiteBlock: Color { .hexDanger }

    // MARK: Status washes (pastel fills)

    static let hexOKWash = dynamic(light: (0.87, 0.92, 0.86), dark: (0.19, 0.25, 0.21))
    static let hexDangerWash = dynamic(light: (0.97, 0.88, 0.84), dark: (0.30, 0.19, 0.17))
    static let hexWarningWash = dynamic(light: (0.98, 0.92, 0.79), dark: (0.28, 0.23, 0.14))
    static let hexInfoWash = dynamic(light: (0.92, 0.90, 0.98), dark: (0.23, 0.21, 0.31))
    static let hexNeutralWash = dynamic(light: (0.92, 0.90, 0.87), dark: (0.24, 0.23, 0.22))

    // MARK: Control tints (white labels on top)

    /// App-wide control tint: selection, prominent buttons, switches.
    static let hexTint = dynamic(light: (0.24, 0.44, 0.33), dark: (0.36, 0.58, 0.46))
    /// Tint of destructive prominent buttons and of "block" switches.
    static let hexDangerTint = dynamic(light: (0.66, 0.26, 0.19), dark: (0.70, 0.38, 0.31))

    // MARK: Surfaces

    /// The window canvas: cream in light mode, warm charcoal in dark mode.
    static let surfaceCanvas = dynamic(light: (0.973, 0.957, 0.933), dark: (0.133, 0.122, 0.114))
    /// Cards and panels, one step above the canvas.
    static let surfaceCard = dynamic(light: (1.0, 0.992, 0.980), dark: (0.176, 0.165, 0.153))
    /// Recessed areas: the map plate, code blocks, wells.
    static let surfaceInset = dynamic(light: (0.945, 0.925, 0.894), dark: (0.106, 0.098, 0.090))
    /// Hairline borders of cards and wells.
    static let surfaceStroke = dynamic(light: (0.24, 0.20, 0.15), dark: (1.0, 0.95, 0.88), lightAlpha: 0.10, darkAlpha: 0.09)
    /// Soft card shadow; nearly invisible in dark mode, where borders do the work.
    static let surfaceShadow = dynamic(light: (0.30, 0.22, 0.14), dark: (0, 0, 0), lightAlpha: 0.07, darkAlpha: 0.30)

    // MARK: Map

    /// Land dots of the map.
    static let mapLand = dynamic(light: (0.85, 0.82, 0.78), dark: (0.27, 0.25, 0.23))
    /// Land dots of countries the Mac currently talks to.
    static let mapLandContacted = dynamic(light: (0.72, 0.80, 0.72), dark: (0.29, 0.38, 0.32))

    // MARK: Brand (fixed, appearance-independent)

    /// Deep plum ink of the app icon background.
    static let brandPlum = Color(red: 0.20, green: 0.16, blue: 0.24)
    /// Darker end of the icon gradient.
    static let brandNight = Color(red: 0.11, green: 0.09, blue: 0.12)
    /// Cream of the mark on the icon.
    static let brandCream = Color(red: 0.98, green: 0.95, blue: 0.90)
    /// Pastel lavender of the mark.
    static let brandLavender = Color(red: 0.78, green: 0.72, blue: 0.97)
    /// Pastel sage of the mark.
    static let brandSage = Color(red: 0.66, green: 0.85, blue: 0.71)
    /// Honey spark of the mark.
    static let brandHoney = Color(red: 0.98, green: 0.82, blue: 0.50)

    /// A color that follows the light or dark appearance. Components are sRGB, 0...1.
    static func dynamic(
        light: (Double, Double, Double),
        dark: (Double, Double, Double),
        lightAlpha: Double = 1,
        darkAlpha: Double = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

// MARK: - Spacing

/// The spacing scale, on a 4-point grid. Use these instead of literal paddings.
enum Spacing {
    /// 2 pt: between a title and its subtitle.
    static let xxs: CGFloat = 2
    /// 4 pt: inside pills and tags.
    static let xs: CGFloat = 4
    /// 8 pt: between related controls.
    static let sm: CGFloat = 8
    /// 12 pt: between rows, inside banners.
    static let md: CGFloat = 12
    /// 16 pt: card padding, between cards in an inspector.
    static let lg: CGFloat = 16
    /// 24 pt: screen margins, between sections.
    static let xl: CGFloat = 24
    /// 32 pt: between major groups of a screen.
    static let xxl: CGFloat = 32
}

// MARK: - Corner radii

/// Corner radii. Always draw them with `style: .continuous`.
enum Radius {
    /// 4 pt: code tags, country codes.
    static let xs: CGFloat = 4
    /// 7 pt: hover and selection highlights of rows.
    static let sm: CGFloat = 7
    /// 10 pt: banners, tiles, rows inside a card.
    static let md: CGFloat = 10
    /// 14 pt: cards and panels.
    static let lg: CGFloat = 14
    /// 20 pt: hero areas and sheets.
    static let xl: CGFloat = 20
}

// MARK: - Typography

extension Font {
    /// Screen titles: New York (the system serif), semibold.
    static var displayTitle: Font { .system(.title, design: .serif, weight: .semibold) }
    /// Hero titles in sheets and empty states.
    static var displayLarge: Font { .system(.largeTitle, design: .serif, weight: .semibold) }
    /// Section titles inside a screen.
    static var sectionTitle: Font { .system(.title3, design: .serif, weight: .semibold) }
    /// Small uppercase labels above groups (use with `.textCase(.uppercase)` and tracking).
    static var eyebrow: Font { .system(.caption, design: .default, weight: .semibold) }
    /// Big numbers: SF Pro Rounded with tabular digits.
    static var metricValue: Font { .system(.title2, design: .rounded, weight: .semibold).monospacedDigit() }
    /// Technical data (addresses, ports, hashes, paths) in body size.
    static var dataMono: Font { .system(.body, design: .monospaced) }
    /// Technical data in callout size.
    static var dataMonoCallout: Font { .system(.callout, design: .monospaced) }
    /// Technical data in caption size.
    static var dataMonoCaption: Font { .system(.caption, design: .monospaced) }
}

// MARK: - Motion

/// Animation presets. Apply them with `.motion(_:value:)` so Reduce Motion is respected.
enum Motion {
    /// Hover and press feedback.
    static var quick: Animation { .easeOut(duration: 0.12) }
    /// Appearing and disappearing content, selection changes.
    static var standard: Animation { .snappy(duration: 0.25) }
    /// Larger layout changes.
    static var gentle: Animation { .smooth(duration: 0.4) }
}

/// Runs `animation` when `value` changes, unless the user turned on Reduce Motion.
struct ReducibleAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Animates changes of `value` with `animation`, or not at all under Reduce Motion.
    ///
    ///     row.motion(Motion.quick, value: isHovered)
    func motion<Value: Equatable>(_ animation: Animation = Motion.standard, value: Value) -> some View {
        modifier(ReducibleAnimation(animation: animation, value: value))
    }
}

// MARK: - Hover

/// The single item under the pointer, shared by every window.
///
/// SwiftUI's `@State` is off limits in this package (see `WindowState`), so hover feedback
/// stores its state here. Only one thing can be under the pointer at a time, so one shared
/// value is enough. Use `.hoverHighlight(_:)` rather than this class directly.
@MainActor
@Observable
final class HoverState {
    static let shared = HoverState()

    /// Identifier of the hovered item. Namespace your identifiers ("country:FR", "rule:<uuid>")
    /// so two screens never share one.
    var hoveredID: AnyHashable?

    func isHovered(_ id: AnyHashable) -> Bool { hoveredID == id }
}

/// Highlights a row or tile under the pointer with a soft rounded wash.
struct HoverHighlight: ViewModifier {
    let id: AnyHashable
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let hovered = HoverState.shared.isHovered(id)
        content
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.05 : 0))
            )
            .onHover { inside in
                let state = HoverState.shared
                if inside {
                    state.hoveredID = id
                } else if state.hoveredID == id {
                    state.hoveredID = nil
                }
            }
            .motion(Motion.quick, value: hovered)
    }
}

extension View {
    /// Adds hover feedback to a row or tile that is not in a `List` (lists highlight their own rows).
    ///
    ///     RuleRow(rule: rule).hoverHighlight("rule:\(rule.id)")
    func hoverHighlight<ID: Hashable>(_ id: ID, cornerRadius: CGFloat = Radius.md) -> some View {
        modifier(HoverHighlight(id: AnyHashable(id), cornerRadius: cornerRadius))
    }
}
