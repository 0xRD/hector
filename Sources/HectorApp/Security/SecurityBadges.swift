import AppKit
import HectorCore
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

    var kind: StatusKind {
        switch self {
        case .apple, .appStore, .developerIDNotarized: .ok
        case .developerID, .otherCertificate: .neutral
        case .adHoc: .warning
        case .unsigned, .invalid: .danger
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
///
/// Takes the controller as a parameter rather than from the environment: it is drawn inside List
/// rows and Table cells, which AppKit may rebuild before SwiftUI attaches the environment, and a
/// missing environment object is a crash.
struct SignatureBadge: View {
    let security: SecurityController
    let path: String?

    var body: some View {
        switch path.flatMap({ security.signatures[$0] }) {
        case .analyzed(let info)?:
            StatusPill(info.trustLevel.shortLabel, kind: info.trustLevel.kind, systemImage: info.trustLevel.symbol, size: .small)
                .help(info.signerName.map { "\(info.trustLevel.label) · \($0)" } ?? info.trustLevel.label)
        case .analyzing?:
            ProgressView().controlSize(.mini)
        case .failed(let message)?:
            StatusPill("Unreadable", kind: .neutral, systemImage: "questionmark", size: .small)
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

    var scoreKind: StatusKind {
        guard let stats = report?.stats else { return .neutral }
        if stats.malicious > 0 { return .danger }
        if stats.suspicious > 0 { return .warning }
        return .ok
    }
}

/// The VirusTotal result for the code at `path`, or a button to look it up.
/// Takes the controller as a parameter, for the same reason as `SignatureBadge`.
struct VirusTotalBadge: View {
    let security: SecurityController
    let path: String?

    var body: some View {
        if let path {
            switch security.virusTotal[path] {
            case .done(let lookup)?:
                StatusPill(lookup.scoreLabel, kind: lookup.scoreKind,
                           systemImage: lookup.isKnown ? "shield.lefthalf.filled" : "questionmark.circle", size: .small)
                    .help(lookup.isKnown ? "Engines flagging the file / engines with a verdict" : "VirusTotal has never seen this file")
            case .checking?:
                ProgressView().controlSize(.mini).help("Hashing and looking up (4 lookups per minute on the free tier)")
            case .failed(let message)?:
                Button {
                    Task { await security.checkVirusTotal(path: path) }
                } label: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.hectorWarning)
                }
                .buttonStyle(.borderless)
                .help("\(message) Click to retry.")
            case nil:
                Button("Check") { Task { await security.checkVirusTotal(path: path) } }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(security.hasAPIKey
                          ? "Send the file's SHA-256 (never the file) to VirusTotal"
                          : "Open the file's page on virustotal.com (its SHA-256 only). Add an API key in Settings to see results here.")
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
                SymbolTile("questionmark", tint: .hectorNeutral, size: size, shape: .rounded)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Signature and VirusTotal details of one piece of code, for the inspectors.
struct CodeDetailsSection: View {
    let security: SecurityController
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Card {
                SectionHeader("Code signature", systemImage: "signature", style: .eyebrow)
                signature
            }
            Card {
                SectionHeader("VirusTotal", systemImage: "shield.lefthalf.filled", style: .eyebrow)
                virusTotal
            }
        }
    }

    @ViewBuilder
    private var signature: some View {
        switch security.signatures[path] {
        case .analyzed(let info)?:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                DetailRow("Trust") { SignatureBadge(security: security, path: path) }
                if let problem = info.validationError { DetailRow("Problem", value: problem) }
                if let signer = info.signerName { DetailRow("Signer", value: signer, copyable: true) }
                if info.isSigned {
                    DetailRow("Team ID", value: info.teamIdentifier ?? "–", monospaced: true, copyable: info.teamIdentifier != nil)
                    DetailRow("Identifier", value: info.signingIdentifier ?? "–", copyable: info.signingIdentifier != nil)
                    DetailRow("Notarized", value: info.isNotarized ? "Yes" : (info.isApplePlatform || info.isAppStore ? "Not needed" : "No"))
                    DetailRow("Hardened runtime", value: info.hasHardenedRuntime ? "Yes" : "No")
                }
            }
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
                    VirusTotalBadge(security: security, path: path)
                    if let label = lookup.report?.threatLabel { Text(label).font(.callout).foregroundStyle(.secondary) }
                }
                CopyableText(lookup.sha256, font: .system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack {
                    Link("Open the report", destination: lookup.permalink)
                    Button("Refresh") { Task { await security.checkVirusTotal(path: path, refresh: true) } }
                    if lookup.fromCache {
                        Text("cached \(Display.relative(lookup.fetchedAt))")
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
                Button(security.hasAPIKey ? "Check with VirusTotal" : "Open on VirusTotal") {
                    Task { await security.checkVirusTotal(path: path) }
                }
                Text(security.hasAPIKey
                     ? "Only the file's SHA-256 is sent, never the file."
                     : "Opens the file's page on virustotal.com in your browser: only its SHA-256 is in the address. Add an API key in Settings (⌘,) to see results here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
