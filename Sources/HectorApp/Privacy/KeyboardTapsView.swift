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

/// One line of the table: identical taps of one process (same mode, state, scope and keys)
/// shown once, with how many there are.
struct TapRow: Identifiable {
    let tap: KeyboardTap
    let count: Int
    var id: KeyboardTap.ID { tap.id }

    static func grouped(_ taps: [KeyboardTap]) -> [TapRow] {
        var order: [String] = []
        var groups: [String: [KeyboardTap]] = [:]
        for tap in taps {
            let key = "\(tap.tapping.pid)|\(tap.isActive)|\(tap.isEnabled)|\(tap.scopeLabel)|\(tap.eventsLabel)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(tap)
        }
        return order.compactMap { key in groups[key].map { TapRow(tap: $0[0], count: $0.count) } }
    }
}

/// Apps that intercept keystrokes through an event tap, in the spirit of ReiKey.
struct KeyboardTapsView: View {
    @Environment(PrivacyController.self) private var privacy
    @Environment(SecurityController.self) private var security
    @Environment(WindowState.self) private var state

    var body: some View {
        @Bindable var state = state
        let taps = TapRow.grouped(visibleTaps)
        VStack(spacing: 0) {
            header
            Divider()
            content(taps)
        }
        .fillsSplitPane()
        .inspector(isPresented: $state.showTapDetails) {
            KeyboardTapDetailView(security: security, tap: selectedTap)
                .fillsSplitPane()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .task {
            if privacy.taps == nil { await refresh() }
        }
    }

    @ViewBuilder
    private func content(_ taps: [TapRow]) -> some View {
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
        } else if taps.isEmpty && state.search.isEmpty {
            EmptyStateView("Nothing is listening", systemImage: "keyboard",
                           message: "Every keyboard tap is switched off, so none receives keystrokes.", tint: .hectorOK)
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
        @Bindable var state = state
        return ScreenHeader("Keyboard taps", subtitle: summary, systemImage: "keyboard", tint: .hectorInfo, pinned: true) {
            Toggle("Switched off", isOn: $state.tapsShowSwitchedOff).toggleStyle(.checkbox)
                .help("Also list taps their app has switched off: they receive nothing")
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(privacy.isLoadingTaps)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func table(_ rows: [TapRow]) -> some View {
        @Bindable var privacy = privacy
        return Table(rows, selection: $privacy.selectedTap) {
            TableColumn("App") { row in
                HStack(spacing: 6) {
                    TapProcessCell(process: row.tap.tapping)
                    if row.count > 1 {
                        Text("× \(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help("\(row.count) identical taps from this process")
                    }
                }
            }
            .width(min: 200, ideal: 280)
            TableColumn("Sees") { row in
                Text(row.tap.scopeLabel).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 120, max: 200)
            TableColumn("Mode") { row in
                TapModePill(tap: row.tap)
            }
            .width(min: 90, ideal: 110, max: 140)
            TableColumn("Keys") { row in
                Text(row.tap.eventsLabel).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 160, max: 240)
            TableColumn("Signature") { row in
                SignatureBadge(security: security, path: PrivacyController.codePath(of: row.tap.tapping))
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
        let all = (privacy.taps ?? []).filter { state.tapsShowSwitchedOff || $0.isEnabled }
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
            InspectorScrollView {
                content(tap)
            }
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
