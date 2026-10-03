import AppKit
import NetbiteCore
import SwiftUI

extension TrustLevel {
    var symbol: String {
        switch self {
        case .apple: "apple.logo"
        case .appStore: "bag"
        case .developerIDNotarized: "checkmark.seal.fill"
        case .developerID: "checkmark.seal"
        case .otherCertificate: "signature"
        case .adHoc: "questionmark.diamond"
        case .unsigned: "exclamationmark.triangle.fill"
        case .invalid: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .apple, .appStore, .developerIDNotarized: .netbiteAccent
        case .developerID, .otherCertificate: .secondary
        case .adHoc: .orange
        case .unsigned, .invalid: .netbiteBlock
        }
    }

    /// Short text for a table cell.
    var shortLabel: String {
        switch self {
        case .apple: "Apple"
        case .appStore: "App Store"
        case .developerIDNotarized: "Notarized"
        case .developerID: "Developer ID"
        case .otherCertificate: "Signed"
        case .adHoc: "Ad hoc"
        case .unsigned: "Unsigned"
        case .invalid: "Invalid"
        }
    }

    /// Worth a second look: code that Gatekeeper would not vouch for.
    var isConcerning: Bool { [.adHoc, .unsigned, .invalid].contains(self) }
}

/// The trust level of the code at `path`, or a spinner while it is analyzed.
struct SignatureBadge: View {
    @Environment(SecurityController.self) private var security
    let path: String?

    var body: some View {
        switch path.flatMap({ security.signatures[$0] }) {
        case .analyzed(let info)?:
            Label(info.trustLevel.shortLabel, systemImage: info.trustLevel.symbol)
                .labelStyle(BadgeLabelStyle(color: info.trustLevel.color, iconSize: 9))
                .help(info.signerName.map { "\(info.trustLevel.label) · \($0)" } ?? info.trustLevel.label)
        case .analyzing?:
            ProgressView().controlSize(.mini)
        case .failed(let message)?:
            Label("Unreadable", systemImage: "questionmark")
                .labelStyle(BadgeLabelStyle(color: .secondary, iconSize: 9))
                .help(message)
        case nil:
            Text("–").foregroundStyle(.tertiary)
        }
    }
}

extension VirusTotalLookup {
    /// "0/72", "3/70", or "Unknown".
    var scoreLabel: String {
        guard let stats = report?.stats else { return "Unknown" }
        return "\(stats.malicious + stats.suspicious)/\(stats.verdictCount)"
    }

    var scoreColor: Color {
        guard let stats = report?.stats else { return .secondary }
        if stats.malicious > 0 { return .netbiteBlock }
        if stats.suspicious > 0 { return .orange }
        return .netbiteAccent
    }
}

/// The VirusTotal result for the code at `path`, or a button to look it up.
struct VirusTotalBadge: View {
    @Environment(SecurityController.self) private var security
    let path: String?

    var body: some View {
        if let path {
            switch security.virusTotal[path] {
            case .done(let lookup)?:
                Label(lookup.scoreLabel, systemImage: lookup.isKnown ? "shield.lefthalf.filled" : "questionmark.circle")
                    .labelStyle(BadgeLabelStyle(color: lookup.scoreColor, iconSize: 9))
                    .help(lookup.isKnown ? "Engines flagging the file / engines with a verdict" : "VirusTotal has never seen this file")
            case .checking?:
                ProgressView().controlSize(.mini).help("Hashing and looking up (4 lookups per minute on the free tier)")
            case .failed(let message)?:
                Button {
                    Task { await security.checkVirusTotal(path: path) }
                } label: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("\(message) Click to retry.")
            case nil:
                Button("Check") { Task { await security.checkVirusTotal(path: path) } }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Send the file's SHA-256 (never the file) to VirusTotal")
            }
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }
}

/// The icon of an app bundle or a file, by path.
struct PathIcon: View {
    let path: String?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let path, FileManager.default.fileExists(atPath: path) {
                Image(nsImage: IconCache.icon(for: path)).resizable()
            } else {
                Image(systemName: "questionmark.square.dashed").resizable().scaledToFit().foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Signature and VirusTotal details of one piece of code, for the inspectors.
struct CodeDetailsSection: View {
    @Environment(SecurityController.self) private var security
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Code signature")
            signature
            SectionTitle("VirusTotal").padding(.top, 6)
            virusTotal
        }
    }

    @ViewBuilder
    private var signature: some View {
        switch security.signatures[path] {
        case .analyzed(let info)?:
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                row("Trust") { SignatureBadge(path: path) }
                if let problem = info.validationError { row("Problem") { Text(problem) } }
                if let signer = info.signerName { row("Signer") { Text(signer).textSelection(.enabled) } }
                if info.isSigned {
                    row("Team ID") { Text(info.teamIdentifier ?? "–").monospaced().textSelection(.enabled) }
                    row("Identifier") { Text(info.signingIdentifier ?? "–").textSelection(.enabled) }
                    row("Notarized") { Text(info.isNotarized ? "Yes" : (info.isApplePlatform || info.isAppStore ? "Not needed" : "No")) }
                    row("Hardened runtime") { Text(info.hasHardenedRuntime ? "Yes" : "No") }
                }
            }
            .font(.callout)
        case .analyzing?:
            ProgressView().controlSize(.small)
        case .failed(let message)?:
            Text(message).font(.callout).foregroundStyle(.secondary)
        case nil:
            Button("Analyze") { Task { await security.analyzeSignatures(of: [path]) } }
        }
    }

    @ViewBuilder
    private var virusTotal: some View {
        switch security.virusTotal[path] {
        case .done(let lookup)?:
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VirusTotalBadge(path: path)
                    if let label = lookup.report?.threatLabel { Text(label).font(.callout).foregroundStyle(.secondary) }
                }
                Text(lookup.sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                HStack {
                    Link("Open the report", destination: lookup.permalink)
                    Button("Refresh") { Task { await security.checkVirusTotal(path: path, refresh: true) } }
                    if lookup.fromCache {
                        Text("cached \(lookup.fetchedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .checking?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up… the free tier allows 4 lookups per minute.").font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message)?:
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await security.checkVirusTotal(path: path) } }
            }
        case nil:
            VStack(alignment: .leading, spacing: 6) {
                Button("Check with VirusTotal") { Task { await security.checkVirusTotal(path: path) } }
                Text("Only the file's SHA-256 is sent, never the file.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ value: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            value()
        }
    }
}

/// Opens Finder on `path`.
@MainActor
func revealInFinder(_ path: String) {
    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
}

@MainActor
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
