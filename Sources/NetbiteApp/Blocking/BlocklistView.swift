import NetbiteCore
import SwiftUI

/// The blocklist editor: helper status, countries, personal rules, and the pending changes bar.
struct BlocklistView: View {
    @Environment(BlockingController.self) private var blocking

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                ScreenHeader(
                    "Blocklists",
                    subtitle: "System-wide rules: they apply to every app on this Mac.",
                    systemImage: "nosign",
                    tint: .hexDanger
                )
                HelperCard()
                if blocking.pendingChanges > 0 { PendingBar() }
                if let error = blocking.lastError {
                    Banner("Something went wrong", message: error, kind: .danger)
                }
                CountriesSection()
                RulesSection()
                Banner(
                    "Blocking is for the whole Mac",
                    message: "Netbite shows traffic per app but blocks for every app. Blocking a destination for a single app, the way LuLu or Little Snitch do, needs a Network Extension signed with a paid Apple Developer account.",
                    kind: .info,
                    systemImage: "info.circle"
                )
            }
            .padding(Spacing.xl + 4)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .canvasBackground()
        .task { await blocking.refresh() }
    }
}

// MARK: - Helper

private struct HelperCard: View {
    @Environment(BlockingController.self) private var blocking
    @Environment(WindowState.self) private var state

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SymbolTile(icon, tint: iconColor, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            Spacer(minLength: 0)
            if blocking.isWorking { ProgressView().controlSize(.small) }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var icon: String {
        switch blocking.helper {
        case .ready(let status) where status.pfEnabled && status.anchorLoaded: "checkmark.shield.fill"
        case .ready: "shield"
        case .notInstalled: "shield.slash"
        case .unreachable: "exclamationmark.shield"
        case .checking: "shield"
        }
    }

    private var iconColor: Color {
        if case .ready(let status) = blocking.helper, status.pfEnabled, status.anchorLoaded { return .hexOK }
        if case .unreachable = blocking.helper { return .hexDanger }
        if case .ready = blocking.helper { return .hexInfo }
        return .hexNeutral
    }

    @ViewBuilder
    private var content: some View {
        switch blocking.helper {
        case .checking:
            Text("Checking the Netbite helper…").font(.headline)
        case .notInstalled:
            Text("Blocking needs the Netbite helper").font(.headline)
            Text("A small service that runs as root to manage pf and the Netbite section of /etc/hosts. macOS asks for an administrator password once. It also lets Netbite see system processes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Install helper…") { Task { await blocking.installHelper() } }
                .buttonStyle(.borderedProminent)
                .disabled(blocking.isWorking)
                .padding(.top, 4)
        case .unreachable(let message):
            Text("The Netbite helper does not answer").font(.headline)
            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Retry") { Task { await blocking.refresh() } }
                Button("Reinstall…") { Task { await blocking.installHelper() } }
            }
            .padding(.top, 4)
        case .ready(let status):
            Text(status.pfEnabled && status.anchorLoaded ? "pf firewall enabled" : "Helper ready, nothing enforced yet")
                .font(.headline)
            Text(summary(status)).foregroundStyle(.secondary)
            ForEach(status.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Remove all rules") { Task { await blocking.flush() } }
                    .disabled(blocking.isWorking || status.appliedAt == nil)
                Button("Uninstall helper…") { Task { await blocking.uninstallHelper() } }
                    .disabled(blocking.isWorking)
                    .help("Removes the helper and every rule; keeps the app and your blocklist.")
                Button("Uninstall Netbite…") { state.showUninstall = true }
                    .help("Removes Netbite and everything it created on this Mac.")
            }
            .padding(.top, 4)
        }
    }

    private func summary(_ status: HelperStatus) -> String {
        var parts = [
            "\(status.blockTableCount) networks",
            "\(status.geoTableCount.formatted()) country networks",
            "\(status.hostsDomainCount) domains",
        ]
        if let date = status.appliedAt {
            parts.append("applied \(date.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ") + " · helper \(status.version)"
    }
}

/// Shown while the draft differs from what pf enforces.
struct PendingBar: View {
    @Environment(BlockingController.self) private var blocking
    /// Actions under the text, for the narrow details panel.
    var compact = false

    var body: some View {
        Banner(
            blocking.pendingChanges == 1 ? "1 pending change" : "\(blocking.pendingChanges) pending changes",
            message: "Nothing changes until you apply: pf reloads its tables and /etc/hosts is rewritten.",
            kind: .warning,
            systemImage: "clock.badge.exclamationmark",
            actionsBelow: compact
        ) {
            Button("Discard") { blocking.discard() }
                .disabled(blocking.isWorking)
            if blocking.isHelperReady {
                Button("Apply to pf") { Task { await blocking.apply() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(blocking.isWorking)
                    .help("Send the blocklist to the helper, which enforces it with pf")
            } else {
                Button("Install Helper…") { Task { await blocking.installHelper() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(blocking.isWorking)
            }
        }
    }
}

// MARK: - Countries

private struct CountriesSection: View {
    @Environment(BlockingController.self) private var blocking
    @Environment(ConnectionMonitor.self) private var monitor
    @Environment(WindowState.self) private var state

    private static let commonlyBlocked = ["CN", "RU", "IR", "KP", "BY"]

    var body: some View {
        @Bindable var state = state
        let contacted = contactedCountries
        let query = state.countrySearch.trimmingCharacters(in: .whitespaces).lowercased()
        let match: (String) -> Bool = { code in
            query.isEmpty || code.lowercased().contains(query) || Countries.name(code).lowercased().contains(query)
        }
        let seen = contacted.keys.filter { !Self.commonlyBlocked.contains($0) }.sorted { Countries.name($0) < Countries.name($1) }
        let others = Self.allCountries.filter { !Self.commonlyBlocked.contains($0) && contacted[$0] == nil }

        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(
                "Countries",
                subtitle: "Block every IP range of a country (DB-IP Lite, IPv4 and IPv6). All off by default.",
                systemImage: "flag"
            ) {
                TextField("Find a country", text: $state.countrySearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .accessibilityLabel("Find a country")
            }
            group("Commonly blocked", Self.commonlyBlocked.filter(match), contacted: contacted)
            group("Contacted this session", seen.filter(match), contacted: contacted)
            if query.isEmpty {
                DisclosureGroup("All countries (\(others.count))", isExpanded: $state.showAllCountries) {
                    grid(others, contacted: contacted).padding(.top, 8)
                }
            } else {
                group("Other countries", others.filter(match), contacted: contacted)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ codes: [String], contacted: [String: Int]) -> some View {
        if !codes.isEmpty {
            SectionHeader(title, style: .eyebrow)
                .padding(.top, Spacing.xs)
            grid(codes, contacted: contacted)
        }
    }

    private func grid(_ codes: [String], contacted: [String: Int]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
            ForEach(codes, id: \.self) { code in
                CountryTile(code: code, contactedCount: contacted[code] ?? 0)
            }
        }
    }

    /// Countries the apps talked to this session, with the number of destinations in each.
    private var contactedCountries: [String: Int] {
        var counts: [String: Int] = [:]
        for app in monitor.apps.values {
            for destination in app.destinations.values {
                if let country = destination.country { counts[country, default: 0] += 1 }
            }
        }
        return counts
    }

    private static let allCountries = WorldData.countryCodes.sorted { Countries.name($0) < Countries.name($1) }
}

private struct CountryTile: View {
    @Environment(BlockingController.self) private var blocking
    let code: String
    let contactedCount: Int

    var body: some View {
        let blocked = blocking.isCountryBlocked(code)
        let pending = blocked != blocking.applied.blockedCountries.contains(code)
        HStack(spacing: 10) {
            CountryBadge(code: code, showName: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(Countries.name(code)).fontWeight(.medium).lineLimit(1)
                Text(subtitle(blocked: blocked, pending: pending))
                    .font(.caption)
                    .foregroundStyle(pending ? Color.hexWarning : (blocked ? Color.hexDanger : Color.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("Block all of \(Countries.name(code))", isOn: Binding(
                get: { blocked },
                set: { blocking.setCountry(code, blocked: $0) }
            ))
            .toggleStyle(.switch)
            .tint(.hexDangerTint)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .hoverHighlight("country:\(code)")
        .cardSurface(cornerRadius: Radius.md, tint: blocked ? Color.hexDanger : nil)
        .motion(Motion.quick, value: blocked)
    }

    private func subtitle(blocked: Bool, pending: Bool) -> String {
        var text: String
        if blocked {
            text = contactedCount > 0 ? "Cuts \(contactedCount) destination\(contactedCount == 1 ? "" : "s") seen" : "Every range blocked"
        } else {
            text = contactedCount > 0 ? "\(contactedCount) destination\(contactedCount == 1 ? "" : "s") this session" : "Not contacted this session"
        }
        return pending ? text + " · not applied" : text
    }
}

// MARK: - Rules

private struct RulesSection: View {
    @Environment(BlockingController.self) private var blocking
    @Environment(WindowState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(
                "My rules",
                subtitle: "Domains go to /etc/hosts; addresses and CIDR ranges go to the pf table. Wildcards (*.example.com) only block the main name.",
                systemImage: "list.bullet.rectangle"
            )
            RuleInput(add: { add() })
            if blocking.draft.rules.isEmpty {
                Card {
                    EmptyStateView(
                        "No rules yet",
                        systemImage: "sparkles",
                        message: "Use “Block This Destination” in the details panel, or add a domain, an IP or a range above.",
                        tint: .hexNeutral,
                        compact: true
                    )
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(blocking.draft.rules) { rule in
                        RuleRow(rule: rule)
                        if rule.id != blocking.draft.rules.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .padding(Spacing.xs)
                .cardSurface()
            }
        }
    }

    private func add() {
        if blocking.addRule(state.newRule, note: state.newRuleNote) {
            state.newRule = ""
            state.newRuleNote = ""
        }
    }
}

/// The new-rule field, its note and the Add button, with inline validation.
private struct RuleInput: View {
    @Environment(WindowState.self) private var state
    let add: @MainActor () -> Void

    var body: some View {
        @Bindable var state = state
        let isInvalid = !state.newRule.isEmpty && RuleTarget(state.newRule) == nil
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                TextField("Domain, IP or CIDR, e.g. tracker.example.com or 203.0.113.0/24", text: $state.newRule)
                    .textFieldStyle(.roundedBorder)
                    .font(.dataMono)
                    .onSubmit { add() }
                    .accessibilityLabel("New rule")
                TextField("Note (optional)", text: $state.newRuleNote)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { add() }
                    .accessibilityLabel("Note for the new rule")
                Button("Add Rule") { add() }
                    .disabled(RuleTarget(state.newRule) == nil)
            }
            if isInvalid {
                Label("Not a valid domain, IP address or CIDR range.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.hexDanger)
            }
        }
        .padding(Spacing.md)
        .cardSurface(cornerRadius: Radius.md)
    }
}

private struct RuleRow: View {
    @Environment(BlockingController.self) private var blocking
    let rule: Rule

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Enable \(rule.target.description)", isOn: Binding(
                get: { rule.isEnabled },
                set: { blocking.setRule(rule.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .tint(.hexDangerTint)
            .labelsHidden()
            .help(rule.isEnabled ? "Turn this rule off" : "Turn this rule on")
            CodeTag(kind)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.target.description)
                    .font(.dataMono)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if let note = rule.note { Text(note).foregroundStyle(.secondary) }
                    if blocking.isPending(rule) {
                        StatusPill(rule.isEnabled ? "Not applied" : "Will be removed", kind: .warning, systemImage: "clock", size: .small)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Text(rule.source == .connections ? "From Connections" : "Manual")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(rule.createdAt, format: .dateTime.year().month().day())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                blocking.removeRule(rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this rule")
            .accessibilityLabel("Delete rule \(rule.target.description)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight("rule:\(rule.id)", cornerRadius: Radius.sm)
    }

    private var kind: String {
        switch rule.target {
        case .domain: "Domain"
        case .network(let cidr): cidr.isSingleAddress ? "IP" : "CIDR"
        }
    }
}
