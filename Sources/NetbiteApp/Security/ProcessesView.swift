import NetbiteCore
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
                ContentUnavailableView("Listing processes…", systemImage: "cpu")
            } else if rows.isEmpty {
                ContentUnavailableView(state.processesFlaggedOnly ? "Nothing flagged" : "No process",
                                       systemImage: "checkmark.shield",
                                       description: Text(state.processesFlaggedOnly
                                                         ? "No process runs from a temporary, Downloads or hidden folder, and none runs deleted code."
                                                         : "Nothing matches the search."))
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
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Running processes").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                    .foregroundStyle(Color.netbiteBlock)
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
                Label("\(connections.count)", systemImage: "network")
                    .labelStyle(BadgeLabelStyle(color: .netbiteAccent, iconSize: 9))
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
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No process selected", systemImage: "cpu",
                                   description: Text("Pick a process to see its code, its parent and its connections."))
        }
    }

    @ViewBuilder
    private func content(_ row: ProcessRow) -> some View {
        let process = row.process
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Process \(process.pid)")
                HStack(spacing: 10) {
                    PathIcon(path: process.appBundlePath ?? process.executablePath, size: 32)
                    Text(process.displayName).font(.title2.bold()).textSelection(.enabled)
                }
                if process.appName != nil, process.appName != process.name {
                    Text(process.name).font(.callout).foregroundStyle(.secondary)
                }
            }

            if !row.flags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.flags.sorted(), id: \.self) { flag in
                        Label(flag.label, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.netbiteBlock)
                    }
                }
                .font(.callout)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                detailRow("Parent") { Text(parentLabel(process)) }
                detailRow("User") { Text(process.userName.map { "\($0) (\(process.userID))" } ?? String(process.userID)) }
                if let started = process.startedAt {
                    detailRow("Started") { Text(started.formatted(date: .abbreviated, time: .standard)) }
                }
                if let path = process.executablePath {
                    detailRow("Executable") {
                        Text(path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if process.arguments.count > 1 {
                    detailRow("Arguments") {
                        Text(process.arguments.dropFirst().joined(separator: " "))
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)

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
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Connections")
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

    private func detailRow<Content: View>(_ label: String, @ViewBuilder _ value: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            value()
        }
    }
}

private struct QuarantineSection: View {
    let info: QuarantineInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Downloaded")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                if let agent = info.agent { GridRow { Text("By").foregroundStyle(.secondary); Text(agent) } }
                if let date = info.downloadedAt {
                    GridRow { Text("On").foregroundStyle(.secondary); Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }
                if let url = info.dataURL {
                    GridRow { Text("From").foregroundStyle(.secondary); Text(url).textSelection(.enabled).lineLimit(3) }
                }
                if let origin = info.originURL {
                    GridRow { Text("Page").foregroundStyle(.secondary); Text(origin).textSelection(.enabled).lineLimit(3) }
                }
                GridRow {
                    Text("Opened").foregroundStyle(.secondary)
                    Text(info.userApproved ? "Approved by the user in Gatekeeper" : "Not approved yet")
                }
            }
            .font(.callout)
        }
    }
}
