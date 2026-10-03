import AppKit
import SwiftUI

extension Color {
    /// Teal accent: allowed traffic, live state, selection.
    static let netbiteAccent = dynamic(light: (0.04, 0.50, 0.45), dark: (0.24, 0.81, 0.75))
    /// Red: blocked traffic.
    static let netbiteBlock = dynamic(light: (0.77, 0.24, 0.24), dark: (1.00, 0.48, 0.42))
    /// Land dots of the map.
    static let mapLand = dynamic(light: (0.79, 0.81, 0.85), dark: (0.25, 0.27, 0.33))
    /// Land dots of countries the Mac currently talks to.
    static let mapLandContacted = dynamic(light: (0.62, 0.78, 0.76), dark: (0.20, 0.36, 0.37))

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
    }
}

/// The Netbite mark: a network globe with a bite taken out of its top-right edge.
struct NetbiteLogo: View {
    var lineWidth: CGFloat = 1.7

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let scale = s / 24
            var globe = Path()
            globe.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
            globe.addEllipse(in: CGRect(x: 7.8, y: 2.5, width: 8.4, height: 19))
            globe.move(to: CGPoint(x: 2.5, y: 12)); globe.addLine(to: CGPoint(x: 21.5, y: 12))
            globe.move(to: CGPoint(x: 4.2, y: 7.3)); globe.addLine(to: CGPoint(x: 19.8, y: 7.3))
            globe.move(to: CGPoint(x: 4.2, y: 16.7)); globe.addLine(to: CGPoint(x: 19.8, y: 16.7))

            var bite = Path(CGRect(x: 0, y: 0, width: 24, height: 24))
            bite.addEllipse(in: CGRect(x: 16.5, y: -0.5, width: 10, height: 10))

            context.scaleBy(x: scale, y: scale)
            context.clip(to: bite, style: FillStyle(eoFill: true))
            context.stroke(globe, with: .color(.netbiteAccent), lineWidth: lineWidth)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A small line chart of recent activity.
struct Sparkline: View {
    let values: [Int]
    var color: Color = .netbiteAccent

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let peak = CGFloat(max(values.max() ?? 1, 1))
            // The available history (up to a minute) always spans the full width.
            let step = size.width / CGFloat(values.count - 1)
            let start: CGFloat = 0
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: start + step * CGFloat(index), y: size.height - 1 - CGFloat(value) / peak * (size.height - 2))
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let destination: Destination

    var body: some View {
        if destination.isLive {
            Label(destination.liveConnections > 1 ? "Live · \(destination.liveConnections)" : "Live", systemImage: "circle.fill")
                .labelStyle(BadgeLabelStyle(color: .netbiteAccent))
        } else {
            Text(destination.lastSeen, format: .relative(presentation: .named))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct BadgeLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct CountryBadge: View {
    let code: String?
    var showName = true

    var body: some View {
        HStack(spacing: 6) {
            Text(code ?? "--")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            if showName {
                Text(Countries.name(code)).lineLimit(1)
            }
        }
    }
}

/// The icon of an app bundle, or a symbol for daemons and tools.
struct AppIcon: View {
    let app: AppGroup
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let path = app.bundlePath {
                Image(nsImage: IconCache.icon(for: path))
                    .resizable()
            } else {
                Image(systemName: app.executablePath?.contains("/bin/") == true ? "terminal" : "gearshape.2")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.22))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}
