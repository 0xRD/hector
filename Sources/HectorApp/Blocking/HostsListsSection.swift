import HectorCore
import SwiftUI

/// The "Lists" section of the Blocklists screen: the built-in hosts lists catalog, one switch per
/// list, with what the helper holds. Switching a list is a pending change, like a country.
struct HostsListsSection: View {
    @Environment(BlockingController.self) private var blocking

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(
                "Lists",
                subtitle: "Community lists of ads, trackers and malware domains, added to /etc/hosts. The helper downloads them and checks for updates every week. All off by default.",
                systemImage: "list.bullet.rectangle.portrait"
            ) {
                if canRefresh {
                    Button("Update Now") { Task { await blocking.refreshHostsLists() } }
                        .disabled(blocking.isWorking)
                        .help("Download the subscribed lists again. macOS may ask for an administrator password.")
                }
            }
            if blocking.isHelperReady && !blocking.helperSupportsLists {
                Banner(
                    "Update the helper to use lists",
                    message: "The installed helper predates hosts lists: it would ignore them.",
                    kind: .warning,
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    Button("Update Helper…") { Task { await blocking.installHelper() } }
                        .disabled(blocking.isWorking)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 10)], spacing: 10) {
                ForEach(HostsListCatalog.all) { source in
                    HostsListTile(source: source)
                }
            }
        }
    }

    private var canRefresh: Bool {
        blocking.isHelperReady && blocking.helperSupportsLists && !blocking.applied.hostsLists.isEmpty
    }
}

private struct HostsListTile: View {
    @Environment(BlockingController.self) private var blocking
    let source: HostsListSource

    var body: some View {
        let enabled: Bool = blocking.isListEnabled(source.id)
        let applied: Bool = blocking.applied.hostsLists.contains(source.id)
        let state: HostsListState? = blocking.listState(source.id)
        HStack(alignment: .top, spacing: 12) {
            SymbolTile("list.bullet.rectangle", tint: enabled ? Color.hectorDanger : Color.hectorNeutral, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(source.name).fontWeight(.medium).lineLimit(1)
                    pill(enabled: enabled, applied: applied, state: state)
                }
                Text(source.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.detail(state))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let error = state?.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.hectorWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Link("\(source.license) · About this list", destination: source.homepage)
                    .font(.caption)
            }
            Spacer(minLength: 4)
            Toggle("Subscribe to \(source.name)", isOn: Binding(
                get: { enabled },
                set: { blocking.setList(source.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .tint(.hectorDangerTint)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Tiles of a row share its height, whatever their text.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hoverHighlight("list:\(source.id)")
        .cardSurface(cornerRadius: Radius.md, tint: enabled ? Color.hectorDanger : nil)
        .motion(Motion.quick, value: enabled)
    }

    @ViewBuilder
    private func pill(enabled: Bool, applied: Bool, state: HostsListState?) -> some View {
        if enabled != applied {
            StatusPill(enabled ? "Not applied" : "Will be removed", kind: .warning, systemImage: "clock", size: .small)
        } else if applied, state?.updatedAt == nil {
            StatusPill("Not downloaded", kind: state?.lastError == nil ? .neutral : .danger, size: .small)
        } else if applied {
            StatusPill("Active", kind: .ok, size: .small)
        }
    }

    /// "72,233 domains · updated 3 days ago", or why there is no copy yet.
    private static func detail(_ state: HostsListState?) -> String {
        guard let state, let updated = state.updatedAt else {
            return "Downloaded by the helper when you apply."
        }
        let domains: String = "\(Display.count(state.domainCount)) domains"
        let when: String = Display.relative(updated)
        var text: String = "\(domains) · updated \(when)"
        if state.invalidLines > 0 {
            text += " · \(Display.count(state.invalidLines)) invalid line\(state.invalidLines == 1 ? "" : "s") ignored"
        }
        return text
    }
}
