import HectorCore
import SwiftUI

/// One line of the process table.
struct ProcessRow: Identifiable {
    let process: RunningProcess
    /// Indentation in the tree; 0 in the flat list.
    let depth: Int
    let flags: Set<ProcessFlag>
    var id: Int32 { process.pid }
}

/// Running processes, in the spirit of TaskExplorer: tree, signature, flags, connections.
struct ProcessesView: View {
    @Environment(SecurityController.self) private var security
    @Environment(WindowState.self) private var state

    var body: some View {
        @Bindable var state = state
        let rows = visibleRows
        VStack(spacing: 0) {
            header(rows: rows)
            Divider()
            if security.processes == nil {
                EmptyStateView("Taking attendance…", systemImage: "cpu", message: "Listing every running process.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .canvasBackground()
            } else if rows.isEmpty {
                EmptyStateView(state.processesFlaggedOnly ? "All quiet" : "Nothing matches",
                               systemImage: state.processesFlaggedOnly ? "checkmark.shield" : "sparkle.magnifyingglass",
                               message: state.processesFlaggedOnly
                                   ? "No process runs from a temporary, Downloads or hidden folder, and none runs code that was deleted."
                                   : "No process matches the search.",
                               tint: state.processesFlaggedOnly ? .hectorOK : .hectorNeutral)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .canvasBackground()
            } else {
                table(rows)
            }
        }
        .inspector(isPresented: $state.showInspector) {
            ProcessDetailView(row: selectedRow)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .task {
            if security.processes == nil { await security.refreshProcesses() }
        }
    }

    private func header(rows: [ProcessRow]) -> some View {
        @Bindable var state = state
        return ScreenHeader("Running processes", subtitle: summary, systemImage: "cpu", tint: .hectorInfo, pinned: true) {
            Toggle("Tree", isOn: $state.processesAsTree).toggleStyle(.checkbox)
                .help("Show children under their parent process")
            Toggle("Flagged only", isOn: $state.processesFlaggedOnly).toggleStyle(.checkbox)
            if security.isCheckingAll {
                Button("Stop VirusTotal") { security.cancelVirusTotal() }
            } else {
                Button {
                    security.checkAllVirusTotal(paths: rows.compactMap { row in
                        // Apple's own binaries are not worth the quota.
                        let path = row.process.executablePath
                        return security.signature(of: path)?.trustLevel == .apple ? nil : path
                    })
                } label: {
                    Label("Check with VirusTotal", systemImage: "shield.lefthalf.filled")
                }
                .disabled(!security.hasAPIKey)
                .help(security.hasAPIKey ? "Look up every listed non-Apple executable (hashes only, 4 per minute)"
                                         : "Add your VirusTotal API key in Settings (⌘,) first")
            }
            Button {
                Task { await security.refreshProcesses() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(security.isLoadingProcesses)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func table(_ rows: [ProcessRow]) -> some View {
        @Bindable var state = state
        return Table(rows, selection: $state.selectedProcess) {
            TableColumn("Process") { row in
                ProcessNameCell(row: row)
            }
            .width(min: 220, ideal: 320)
            TableColumn("PID") { row in
                Text(String(row.process.pid)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60, max: 80)
            TableColumn("User") { row in
                Text(row.process.userName ?? String(row.process.userID)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 90, max: 140)
            TableColumn("Signature") { row in
                SignatureBadge(path: row.process.executablePath)
            }
            .width(min: 90, ideal: 120, max: 160)
            TableColumn("Network") { row in
                ConnectionCountCell(connections: row.process.connections)
            }
            .width(min: 50, ideal: 70, max: 90)
            TableColumn("VirusTotal") { row in
                VirusTotalBadge(path: row.process.executablePath)
            }
            .width(min: 70, ideal: 90, max: 120)
        }
    }

    private var visibleRows: [ProcessRow] {
        guard let snapshot = security.processes else { return [] }
        let query = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        let flat = state.processesFlaggedOnly || !query.isEmpty || !state.processesAsTree
        let ordered: [(process: RunningProcess, depth: Int)]
        if flat {
            let sorted = snapshot.processes.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            ordered = sorted.map { (process: $0, depth: 0) }
        } else {
            ordered = snapshot.treeOrdered()
        }
        return ordered.compactMap { entry -> ProcessRow? in
            let flags = security.processFlags[entry.process.pid] ?? []
            if state.processesFlaggedOnly && flags.isEmpty { return nil }
            if !query.isEmpty && !matches(entry.process, query) { return nil }
            return ProcessRow(process: entry.process, depth: entry.depth, flags: flags)
        }
    }

    private func matches(_ process: RunningProcess, _ query: String) -> Bool {
        if String(process.pid) == query { return true }
        let fields = [process.name, process.appName ?? "", process.executablePath ?? "",
                      process.userName ?? "", process.arguments.joined(separator: " ")]
        return fields.contains { $0.lowercased().contains(query) }
    }

    private var selectedRow: ProcessRow? {
        guard let pid = state.selectedProcess,
              let process = security.processes?.processes.first(where: { $0.pid == pid }) else { return nil }
        return ProcessRow(process: process, depth: 0, flags: security.processFlags[pid] ?? [])
    }

    private var summary: String {
        guard let snapshot = security.processes else { return "Loading…" }
        let flagged = security.processFlags.values.filter { !$0.isEmpty }.count
        let source = snapshot.ranAsRoot || security.processesThroughHelper
            ? "every user, through the helper"
            : "other users' arguments hidden: install the helper to see them"
        return "\(snapshot.processes.count) processes · \(flagged) flagged · \(source)"
    }
}

private struct ProcessNameCell: View {
    let row: ProcessRow

    var body: some View {
        HStack(spacing: 6) {
            PathIcon(path: row.process.appBundlePath ?? row.process.executablePath, size: 16)
            Text(row.process.name).lineLimit(1)
            if !row.flags.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.hectorDanger)
                    .help(row.flags.sorted().map(\.label).joined(separator: "\n"))
            }
        }
        .padding(.leading, CGFloat(min(row.depth, 12)) * 14)
    }
}

private struct ConnectionCountCell: View {
    let connections: [SocketInfo]?

    var body: some View {
        if let connections {
            if connections.isEmpty {
                Text("0").foregroundStyle(.tertiary)
            } else {
                StatusPill("\(connections.count)", kind: .ok, systemImage: "network", size: .small)
            }
        } else {
            Text("–").foregroundStyle(.tertiary).help("Needs the helper")
        }
    }
}

struct ProcessDetailView: View {
    @Environment(SecurityController.self) private var security
    let row: ProcessRow?

    var body: some View {
        if let row {
            ScrollView {
                content(row)
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .canvasBackground()
        } else {
            EmptyStateView("No process selected", systemImage: "cpu",
                           message: "Pick a process to see its code, its parent and its connections.", compact: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ row: ProcessRow) -> some View {
        let process = row.process
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .top, spacing: Spacing.md) {
                PathIcon(path: process.appBundlePath ?? process.executablePath, size: 40)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    SectionHeader("Process", style: .eyebrow)
                    Text(process.displayName).font(Font.sectionTitle).textSelection(.enabled)
                    HStack(spacing: Spacing.xs) {
                        CodeTag("PID \(process.pid)")
                        if process.appName != nil, process.appName != process.name { CodeTag(process.name) }
                    }
                }
            }

            ForEach(row.flags.sorted(), id: \.self) { flag in
                Banner(flag.label, message: flag.explanation, kind: .danger)
            }

            Card {
                SectionHeader("Details", systemImage: "list.bullet.rectangle", style: .eyebrow)
                DetailRow("Parent", value: parentLabel(process))
                DetailRow("User", value: process.userName.map { "\($0) (\(process.userID))" } ?? String(process.userID))
                if let started = process.startedAt {
                    DetailRow("Started", value: started.formatted(date: .abbreviated, time: .standard))
                }
                if let path = process.executablePath { DetailRow("Executable", value: path, monospaced: true) }
                if process.arguments.count > 1 {
                    DetailRow("Arguments", value: process.arguments.dropFirst().joined(separator: " "), monospaced: true)
                }
            }

            if let quarantine = security.quarantineInfo(for: process) {
                QuarantineSection(info: quarantine)
            }

            connections(process.connections)

            if let path = process.executablePath {
                CodeDetailsSection(path: path)
                HStack {
                    Button("Reveal in Finder") { revealInFinder(path) }
                    Button("Copy path") { copyToPasteboard(path) }
                }
            }
        }
    }

    @ViewBuilder
    private func connections(_ connections: [SocketInfo]?) -> some View {
        Card {
            SectionHeader("Connections", systemImage: "network", style: .eyebrow)
            if let connections {
                if connections.isEmpty {
                    Text("None right now").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(connections.enumerated()), id: \.offset) { _, socket in
                        Text(connectionLabel(socket)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } else {
                Text("Readable through the helper only (another user's process).").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func connectionLabel(_ socket: SocketInfo) -> String {
        let remote = socket.remoteAddress.map { address in
            if case .v6 = address { return "[\(address)]:\(socket.remotePort)" }
            return "\(address):\(socket.remotePort)"
        } ?? "–"
        return "\(socket.transport.rawValue.uppercased()) \(remote)" + (socket.tcpState.map { " · \($0)" } ?? "")
    }

    private func parentLabel(_ process: RunningProcess) -> String {
        guard process.parentPID > 0 else { return "–" }
        let parent = security.processes?.processes.first { $0.pid == process.parentPID }
        return parent.map { "\($0.name) (\($0.pid))" } ?? String(process.parentPID)
    }
}

private struct QuarantineSection: View {
    let info: QuarantineInfo

    var body: some View {
        Card(tint: .hectorWarningWash) {
            SectionHeader("Downloaded from the internet", systemImage: "arrow.down.circle", style: .eyebrow)
            if let agent = info.agent { DetailRow("By", value: agent) }
            if let date = info.downloadedAt {
                DetailRow("On", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let url = info.dataURL { DetailRow("From", value: url, monospaced: true) }
            if let origin = info.originURL { DetailRow("Page", value: origin, monospaced: true) }
            DetailRow("Opened", value: info.userApproved ? "Approved by the user in Gatekeeper" : "Not approved yet")
        }
    }
}
