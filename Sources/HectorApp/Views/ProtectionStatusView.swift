import HectorCore
import SwiftUI

/// The verdict at the bottom of the sidebar: is this Mac protected, or only observed?
/// Clicking it opens Blocklists, where the helper is managed.
struct ProtectionStatusFooter: View {
    @Environment(BlockingController.self) private var blocking
    @Binding var selection: SidebarItem?

    var body: some View {
        let verdict = self.verdict
        Button {
            selection = .blocklists
        } label: {
            HStack(spacing: 10) {
                SymbolTile(verdict.symbol, tint: verdict.kind.color, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verdict.title)
                        .font(.callout.weight(.semibold))
                    Text(verdict.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if blocking.pendingChanges > 0 {
                    StatusPill("\(blocking.pendingChanges)", kind: .warning, systemImage: "clock", size: .small)
                        .help("Changes waiting to be applied")
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .cardSurface(cornerRadius: Radius.md)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.md)
        .help("Open Blocklists")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Protection: \(verdict.title). \(verdict.detail)")
        .accessibilityHint("Opens Blocklists")
        .accessibilityAddTraits(.isButton)
    }

    private struct Verdict {
        let title: String
        let detail: String
        let symbol: String
        let kind: StatusKind
    }

    private var verdict: Verdict {
        switch blocking.helper {
        case .checking:
            return Verdict(title: "Checking protection…", detail: "Asking the helper…", symbol: "shield", kind: .neutral)
        case .notInstalled:
            return Verdict(title: "Observe only", detail: "Install the helper to block", symbol: "eye", kind: .neutral)
        case .unreachable:
            return Verdict(title: "Helper not answering", detail: "Open Blocklists to retry", symbol: "exclamationmark.shield", kind: .danger)
        case .ready(let status):
            guard status.pfEnabled && status.anchorLoaded else {
                return Verdict(title: "Helper ready", detail: "Nothing is blocked yet", symbol: "shield", kind: .info)
            }
            guard let summary = blocking.enforcedSummary else {
                return Verdict(title: "Helper ready", detail: "Nothing is blocked yet", symbol: "shield", kind: .info)
            }
            return Verdict(title: "Blocking on", detail: blocking.enforcedVolume ?? summary, symbol: "checkmark.shield.fill", kind: .ok)
        }
    }
}
