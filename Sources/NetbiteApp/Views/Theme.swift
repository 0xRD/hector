import AppKit
import NetbiteCore
import SwiftUI

// Network-specific pieces of the interface. The design tokens (colors, spacing, type) and the
// generic components live in Sources/NetbiteApp/Design; the brand mark in Design/BrandMark.swift.

/// A small line chart of recent activity, with a soft wash under the line.
struct Sparkline: View {
    let values: [Int]
    var color: Color = .hexOK

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let line = linePath(size: size)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            let wash = Gradient(colors: [color.opacity(0.22), color.opacity(0)])
            context.fill(area, with: .linearGradient(wash, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    private func linePath(size: CGSize) -> Path {
        let peak = CGFloat(max(values.max() ?? 1, 1))
        // The available history (up to a minute) always spans the full width.
        let step: CGFloat = size.width / CGFloat(values.count - 1)
        let usable: CGFloat = size.height - 2
        var path = Path()
        for (index, value) in values.enumerated() {
            let x: CGFloat = step * CGFloat(index)
            let y: CGFloat = size.height - 1 - CGFloat(value) / peak * usable
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

/// The status of a destination: blocked, live, or how long ago it was seen.
struct StatusBadge: View {
    let destination: Destination
    var blockReason: BlockReason? = nil

    var body: some View {
        if let blockReason {
            StatusPill(blockReason.label, kind: .danger, systemImage: "nosign")
        } else if destination.isLive {
            StatusPill(destination.liveConnections > 1 ? "Live · \(destination.liveConnections)" : "Live",
                       kind: .ok, systemImage: "circle.fill")
        } else {
            Text(destination.lastSeen, format: .relative(presentation: .named))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Renders a `Label` as a status pill of any color.
///
/// Kept for existing call sites; prefer `StatusPill`, which picks ink, wash and symbol from a
/// `StatusKind` and stays readable on selected rows.
struct BadgeLabelStyle: LabelStyle {
    let color: Color
    var iconSize: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: min(iconSize, 9), weight: .bold))
            configuration.title.monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.18), lineWidth: 0.5))
        .fixedSize()
    }
}

extension BlockReason {
    var label: String {
        switch self {
        case .network: "Blocked"
        case .country(let code): "Blocked · \(code)"
        }
    }
}

/// A country code tag, optionally followed by the country name.
struct CountryBadge: View {
    let code: String?
    var showName = true

    var body: some View {
        HStack(spacing: 6) {
            CodeTag(code ?? "--")
            if showName {
                Text(Countries.name(code)).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Countries.name(code))
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
                    .padding(size * 0.2)
                    .foregroundStyle(Color.hexNeutral)
                    .background(Color.hexNeutralWash, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
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
