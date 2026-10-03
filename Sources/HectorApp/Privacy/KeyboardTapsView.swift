import HectorCore
import SwiftUI

extension KeyboardTap {
    var modeLabel: String { isActive ? "Active" : "Listen only" }

    var modeHelp: String {
        isActive ? "Receives keystrokes before apps do, and can change or drop them."
                 : "Receives a copy of every keystroke; cannot change them."
    }

    var scopeLabel: String {
        isSystemWide ? "Every app" : "Only \(tapped?.displayName ?? "pid \(tappedPID)")"
    }

    var eventsLabel: String {
        allEvents ? "Every event" : keyEvents.map(\.label).joined(separator: ", ")
    }
}

/// Apps that intercept keystrokes through an event tap, in the spirit of ReiKey.
struct KeyboardTapsView: View {
    @Environment(PrivacyController.self) private var privacy
    @Environment(SecurityController.self) private var security
    @Environment(WindowState.self) private var state

    var body: some View {
        @Bindable var state = state
        let taps = visibleTaps
        VStack(spacing: 0) {
            header
            Divider()
            content(taps)
        }
        .fillsSplitPane()
        .inspector(isPresented: $state.showInspector) {
            KeyboardTapDetailView(security: security, tap: selectedTap)
                .fillsSplitPane()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .task {
            if privacy.taps == nil { await refresh() }
        }
    }

    @ViewBuilder
    private func content(_ taps: [KeyboardTap]) -> some View {
        if let error = privacy.tapsError, privacy.taps == nil {
            EmptyStateView("The tap list could not be read", systemImage: "keyboard", message: error, tint: .hectorWarning)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .canvasBackground()
        } else if privacy.taps == nil {
            EmptyStateView("Listening for listeners…", systemImage: "keyboard", message: "Reading the system's list of event taps.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .canvasBackground()
        } else if privacy.taps?.isEmpty == true {
            EmptyStateView("Nobody is reading your keys", systemImage: "keyboard",
                           message: "No app has an event tap on the keyboard right now.", tint: .hectorOK)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .canvasBackground()
        } else if taps.isEmpty {
            EmptyStateView("Nothing matches", systemImage: "sparkle.magnifyingglass",
                           message: "No keyboard tap matches the search.", tint: .hectorNeutral)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .canvasBackground()
        } else {
            table(taps)
        }
    }

    private var header: some View {
        ScreenHeader("Keyboard taps", subtitle: summary, systemImage: "keyboard", tint: .hectorInfo, pinned: true) {
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(privacy.isLoadingTaps)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func table(_ taps: [KeyboardTap]) -> some View {
        @Bindable var privacy = privacy
        return Table(taps, selection: $privacy.selectedTap) {
            TableColumn("App") { tap in
                TapProcessCell(process: tap.tapping)
            }
            .width(min: 200, ideal: 280)
            TableColumn("Sees") { tap in
                Text(tap.scopeLabel).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 120, max: 200)
            TableColumn("Mode") { tap in
                TapModePill(tap: tap)
            }
            .width(min: 90, ideal: 110, max: 140)
            TableColumn("Keys") { tap in
                Text(tap.eventsLabel).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 160, max: 240)
            TableColumn("Signature") { tap in
                SignatureBadge(security: security, path: PrivacyController.codePath(of: tap.tapping))
            }
            .width(min: 90, ideal: 120, max: 160)
        }
    }

    private func refresh() async {
        await privacy.refreshTaps()
        let paths: [String] = (privacy.taps ?? []).compactMap { PrivacyController.codePath(of: $0.tapping) }
        await security.analyzeSignatures(of: paths)
    }

    private var visibleTaps: [KeyboardTap] {
        let all = privacy.taps ?? []
        let query = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { tap in
            let process = tap.tapping
            let fields: [String] = [process.displayName, process.name, String(process.pid),
                                    process.executablePath ?? "", tap.scopeLabel]
            return fields.contains { $0.lowercased().contains(query) }
        }
    }

    private var selectedTap: KeyboardTap? {
        guard let id = privacy.selectedTap else { return nil }
        return privacy.taps?.first { $0.id == id }
    }

    private var summary: String {
        guard let taps = privacy.taps else { return "Apps that receive your keystrokes through an event tap" }
        // A switched-off tap receives nothing, whatever its mode.
        let active = taps.filter { $0.isActive && $0.isEnabled }.count
        let off = taps.filter { !$0.isEnabled }.count
        let count = taps.count == 1 ? "1 keyboard tap" : "\(taps.count) keyboard taps"
        return "\(count) · \(active) active" + (off > 0 ? " · \(off) switched off" : "") + " · read from the system's event tap list"
    }
}

private struct TapProcessCell: View {
    let process: ProcessIdentity

    var body: some View {
        HStack(spacing: 6) {
            PathIcon(path: PrivacyController.codePath(of: process), size: 16)
            Text(process.displayName).lineLimit(1)
            Text(String(process.pid)).monospacedDigit().foregroundStyle(.tertiary)
        }
    }
}

private struct TapModePill: View {
    let tap: KeyboardTap

    var body: some View {
        if tap.isEnabled {
            StatusPill(tap.modeLabel, kind: tap.isActive ? .warning : .info,
                       systemImage: tap.isActive ? "hand.raised.fill" : "ear", size: .small)
                .help(tap.modeHelp)
        } else {
            StatusPill("Disabled", kind: .neutral, size: .small)
                .help("The tap exists but the system currently does not deliver events to it.")
        }
    }
}

/// The inspector of a keyboard tap: what it sees, and the code behind it.
struct KeyboardTapDetailView: View {
    let security: SecurityController
    let tap: KeyboardTap?

    var body: some View {
        if let tap {
            ScrollView {
                content(tap)
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .canvasBackground()
        } else {
            EmptyStateView("No tap selected", systemImage: "keyboard",
                           message: "Pick a tap to see which app receives the keystrokes and who signed it.", compact: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ tap: KeyboardTap) -> some View {
        let process = tap.tapping
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .top, spacing: Spacing.md) {
                PathIcon(path: PrivacyController.codePath(of: process), size: 40)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    SectionHeader("Receives your keystrokes", style: .eyebrow)
                    Text(process.displayName).font(Font.sectionTitle).textSelection(.enabled)
                    HStack(spacing: Spacing.xs) {
                        CodeTag("PID \(process.pid)")
                        CodeTag("Tap \(tap.tapID)")
                    }
                }
            }
            Card {
                SectionHeader("Tap", systemImage: "keyboard", style: .eyebrow)
                DetailRow("Mode") { TapModePill(tap: tap) }
                DetailRow("Sees", value: tap.isSystemWide ? "Every app's keystrokes" : "\(tap.scopeLabel) (\(tap.tappedPID))")
                DetailRow("Events", value: tap.eventsLabel)
                DetailRow("Location", value: tap.location.label)
            }
            if let path = process.executablePath {
                Card {
                    SectionHeader("Process", systemImage: "cpu", style: .eyebrow)
                    DetailRow("Executable", value: path, monospaced: true)
                    if let bundle = process.bundleIdentifier { DetailRow("Bundle ID", value: bundle, monospaced: true) }
                }
                if let codePath = PrivacyController.codePath(of: process) {
                    CodeDetailsSection(security: security, path: codePath)
                }
                HStack {
                    Button("Reveal in Finder") { revealInFinder(path) }
                    Button("Copy path") { copyToPasteboard(path) }
                }
            } else {
                Banner("The process could not be read", message: "It may have quit since the list was read. Refresh to check.",
                       kind: .neutral)
            }
            Text("Input methods, accessibility tools, window managers and keyboard remappers use taps legitimately. Look twice at anything you do not recognize, especially unsigned code.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
