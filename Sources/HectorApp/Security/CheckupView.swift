import HectorCore
import SwiftUI

extension CheckResult.Status {
    var kind: StatusKind {
        switch self {
        case .pass: .ok
        case .warning: .warning
        case .fail: .danger
        case .unknown: .neutral
        }
    }

    var label: String {
        switch self {
        case .pass: "Pass"
        case .warning: "To review"
        case .fail: "Fail"
        case .unknown: "Unknown"
        }
    }
}

extension CheckResult {
    /// One symbol per check, so the list scans quickly.
    var symbol: String {
        switch id {
        case SecurityCheckup.CheckID.sip: "lock.shield"
        case SecurityCheckup.CheckID.gatekeeper: "checkmark.shield"
        case SecurityCheckup.CheckID.xprotect: "ladybug"
        case SecurityCheckup.CheckID.fileVault: "internaldrive"
        case SecurityCheckup.CheckID.firewall: "flame"
        case SecurityCheckup.CheckID.automaticUpdates: "arrow.down.circle"
        case SecurityCheckup.CheckID.remoteLogin: "terminal"
        case SecurityCheckup.CheckID.screenSharing: "rectangle.on.rectangle"
        case SecurityCheckup.CheckID.fileSharing: "folder"
        case SecurityCheckup.CheckID.remoteAppleEvents: "applescript"
        case SecurityCheckup.CheckID.automaticLogin: "person.badge.key"
        case SecurityCheckup.CheckID.guestAccount: "person.crop.circle.badge.questionmark"
        case SecurityCheckup.CheckID.deviceManagement: "building.2"
        default: "checklist"
        }
    }
}

/// SIP, Gatekeeper, FileVault, the firewall, updates, sharing and MDM, each with how to fix it.
struct CheckupView: View {
    @Environment(CheckupController.self) private var checkup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                content
            }
            .padding(Spacing.xl + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .canvasBackground()
        .task {
            if checkup.report == nil { await checkup.run() }
        }
    }

    private var header: some View {
        ScreenHeader("Security checkup", subtitle: subtitle, systemImage: "checklist", tint: .hectorInfo) {
            if checkup.isRunning {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await checkup.run() }
            } label: {
                Label("Run Again", systemImage: "arrow.clockwise")
            }
            .disabled(checkup.isRunning)
            .help("Read every setting again. Nothing is changed.")
        }
    }

    private var subtitle: String {
        guard let report = checkup.report else { return "Reading this Mac's security settings…" }
        let time: String = report.checkedAt.formatted(date: .omitted, time: .shortened)
        return "\(report.summary) · checked at \(time) · read-only, nothing is changed"
    }

    @ViewBuilder
    private var content: some View {
        if let report = checkup.report {
            CheckupReportView(report: report)
        } else {
            EmptyStateView("Checking…", systemImage: "checklist",
                           message: "SIP, Gatekeeper, FileVault, firewall, updates, sharing and device management.",
                           compact: true)
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.xxl)
        }
    }
}

/// The results, grouped: what needs attention first, then what could not be read, then the rest.
private struct CheckupReportView: View {
    let report: CheckupReport

    var body: some View {
        let attention: [CheckResult] = report.results
            .filter { $0.status == .fail || $0.status == .warning }
            .sorted { $0.status < $1.status }
        let unknown: [CheckResult] = report.results.filter { $0.status == .unknown }
        let passing: [CheckResult] = report.results.filter { $0.status == .pass }

        VStack(alignment: .leading, spacing: Spacing.xl) {
            banners(attention: attention, unknown: unknown)
            if !attention.isEmpty {
                section("Needs attention", subtitle: "Each one says what was found and where to change it.", results: attention)
            }
            if !unknown.isEmpty {
                section("Could not be checked", subtitle: nil, results: unknown)
            }
            if !passing.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    SectionHeader("Passing", subtitle: "\(passing.count) setting\(passing.count == 1 ? "" : "s") where they should be.")
                    PassingCard(results: passing)
                }
            }
        }
    }

    @ViewBuilder
    private func banners(attention: [CheckResult], unknown: [CheckResult]) -> some View {
        if attention.isEmpty && unknown.isEmpty {
            Banner("All quiet", message: "Every setting checked is where it should be.", kind: .ok)
        }
        if unknown.contains(where: { $0.finding.contains("needs the helper") }) {
            Banner("Some settings need root to be read",
                   message: "Hector never asks for a password to read them, so they show as unknown.",
                   kind: .info)
        }
    }

    private func section(_ title: String, subtitle: String?, results: [CheckResult]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title, subtitle: subtitle)
            ForEach(results) { result in
                CheckCard(result: result)
            }
        }
    }
}

/// A check that needs a look: the finding, then how to fix it and a link to System Settings.
private struct CheckCard: View {
    @Environment(CheckupController.self) private var checkup
    let result: CheckResult

    var body: some View {
        Card(spacing: Spacing.md) {
            CheckRow(result: result)
            fix
        }
    }

    private var fix: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionHeader("How to fix", style: .eyebrow)
                Text(result.howToFix)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.md)
            if let url = result.settingsURL {
                Button("Open Settings") { checkup.openSettings(url) }
                    .help("Opens the right pane of System Settings")
            }
        }
        .padding(Spacing.md)
        .insetSurface()
    }
}

/// The checks that pass, as quiet rows in one card.
private struct PassingCard: View {
    let results: [CheckResult]

    var body: some View {
        Card(spacing: Spacing.sm) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { Divider() }
                CheckRow(result: result)
            }
        }
    }
}

private struct CheckRow: View {
    let result: CheckResult

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            SymbolTile(result.symbol, tint: result.status.kind.color, size: 30)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(result.title).fontWeight(.semibold)
                Text(result.finding)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.md)
            StatusPill(result.status.label, kind: result.status.kind, size: .small)
        }
        .accessibilityElement(children: .combine)
    }
}
