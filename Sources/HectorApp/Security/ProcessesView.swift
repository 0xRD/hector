import HectorCore
import SwiftUI

/// One line of the process table.
struct ProcessRow: Identifiable {
    let process: RunningProcess
    /// Indentation in the tree; 0 in the flat list.
    let depth: Int
    let flags: Set<ProcessFlag>
    /// Shown only to connect the tree (an Apple parent of a third-party process): dimmed.
    var isContext = false
    var id: Int32 { process.pid }
}

/// Running processes, in the spirit of TaskExplorer: tree, signature, flags, connections.
struct ProcessesView: View {
    @Environment(SecurityController.self) private var security
    @Environment(BlockingController.self) private var blocking
    @Environment(ConnectionMonitor.self) private var monitor
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
                               tint: state.processesFlaggedOnly ? .hectorOK : .hectorNeutral,
                               hector: state.processesFlaggedOnly ? .ahead : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .canvasBackground()
            } else {
                table(rows)
            }
        }
        .fillsSplitPane()
        .inspector(isPresented: $state.showProcessDetails) {
            ProcessDetailView(security: security, blocking: blocking, monitor: monitor, row: selectedRow)
                .fillsSplitPane()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .task {
            if security.processes == nil { await security.refreshProcesses() }
        }
    }

    private func header(rows: [ProcessRow]) -> some View {
        @Bindable var state = state
        return ScreenHeader("Running processes", subtitle: summary, systemImage: "cpu", tint: .hectorInfo, pinned: true) {
            Toggle("Apple", isOn: $state.processesShowApple).toggleStyle(.checkbox).fixedSize()
                .help("Show Apple's own processes (from /System, /usr, /bin and /sbin)")
            Toggle("Tree", isOn: $state.processesAsTree).toggleStyle(.checkbox).fixedSize()
                .help("Show children under their parent process")
            Toggle("Flagged", isOn: $state.processesFlaggedOnly).toggleStyle(.checkbox).fixedSize()
                .help("Only processes running from a temporary, Downloads or hidden folder, or deleted code")
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
                    Label("VirusTotal", systemImage: "shield.lefthalf.filled").fixedSize()
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
                SignatureBadge(security: security, path: row.process.executablePath)
            }
            .width(min: 90, ideal: 120, max: 160)
            TableColumn("Network") { row in
                ConnectionCountCell(connections: row.process.connections,
                                    blocked: row.process.connections.map { blockedCount($0) } ?? 0)
            }
            .width(min: 50, ideal: 70, max: 90)
            TableColumn("VirusTotal") { row in
                VirusTotalBadge(security: security, path: row.process.executablePath)
            }
            .width(min: 70, ideal: 90, max: 120)
        }
        .contextMenu(forSelectionType: Int32.self) { pids in
            if pids.count == 1, let pid = pids.first,
               let process = security.processes?.processes.first(where: { $0.pid == pid }) {
                ProcessActions.menu(for: process, security: security)
            }
        }
    }

    /// How many of `connections` go to an address the applied blocklist blocks.
    private func blockedCount(_ connections: [SocketInfo]) -> Int {
        let applied = blocking.applied
        return connections.filter { socket in
            guard let address = socket.remoteAddress else { return false }
            return applied.blockReason(for: address, country: monitor.country(for: address)) != nil
        }.count
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
        // Without Apple's processes: the others, plus (in the tree) the Apple parents that connect
        // them. A search or a flag always shows what it found, Apple or not.
        let thirdParty = Set(snapshot.processes.filter { !$0.isAppleSystemCode }.map(\.pid))
        let shown = state.processesShowApple || !query.isEmpty || state.processesFlaggedOnly
            ? nil : (flat ? thirdParty : snapshot.withAncestors(thirdParty))
        return ordered.compactMap { entry -> ProcessRow? in
            let flags = security.processFlags[entry.process.pid] ?? []
            if state.processesFlaggedOnly && flags.isEmpty { return nil }
            if !query.isEmpty && !matches(entry.process, query) { return nil }
            if let shown, !shown.contains(entry.process.pid) { return nil }
            let isContext = shown != nil && !thirdParty.contains(entry.process.pid)
            return ProcessRow(process: entry.process, depth: entry.depth, flags: flags, isContext: isContext)
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
        let apple = snapshot.processes.filter(\.isAppleSystemCode).count
        let count = state.processesShowApple ? "\(snapshot.processes.count) processes"
            : "\(snapshot.processes.count - apple) processes (\(apple) of Apple's hidden)"
        return "\(count) · \(flagged) flagged · \(source)"
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
        .opacity(row.isContext ? 0.5 : 1)
    }
}

/// The number of connections, red when they all go to blocked addresses and honey when some do.
private struct ConnectionCountCell: View {
    let connections: [SocketInfo]?
    /// Connections to an address the applied blocklist blocks.
    let blocked: Int

    var body: some View {
        if let connections {
            if connections.isEmpty {
                Text("0").foregroundStyle(.tertiary)
            } else if blocked == 0 {
                StatusPill("\(connections.count)", kind: .ok, systemImage: "network", size: .small)
            } else if blocked == connections.count {
                StatusPill("\(connections.count)", kind: .danger, systemImage: "nosign", size: .small)
                    .help(blocked == 1 ? "Its connection goes to a blocked address" : "All \(blocked) connections go to blocked addresses")
            } else {
                StatusPill("\(blocked)/\(connections.count)", kind: .warning, systemImage: "nosign", size: .small)
                    .help("\(blocked) of \(connections.count) connections go to blocked addresses")
            }
        } else {
            Text("–").foregroundStyle(.tertiary).help("Needs the helper")
        }
    }
}

struct ProcessDetailView: View {
    let security: SecurityController
    let blocking: BlockingController
    let monitor: ConnectionMonitor
    let row: ProcessRow?

    var body: some View {
        if let row {
            InspectorScrollView {
                content(row)
            }
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
                    CopyableText(process.displayName, font: Font.sectionTitle, id: "process-name")
                    HStack(spacing: Spacing.xs) {
                        CodeTag("PID \(process.pid)")
                            .onTapGesture { CopyFeedback.shared.copy(String(process.pid), id: "process-pid") }
                            .help("Click to copy the PID")
                        if process.appName != nil, process.appName != process.name { CodeTag(process.name) }
                        if CopyFeedback.shared.copiedID == AnyHashable("process-pid") {
                            Label("Copied", systemImage: "checkmark")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.hectorOK)
                        }
                    }
                }
            }

            ForEach(row.flags.sorted(), id: \.self) { flag in
                Banner(flag.label, message: flag.explanation, kind: .danger)
            }

            Card {
                SectionHeader("Details", systemImage: "list.bullet.rectangle", style: .eyebrow)
                DetailRow("Parent", value: parentLabel(process), copyable: true)
                DetailRow("User", value: process.userName.map { "\($0) (\(process.userID))" } ?? String(process.userID), copyable: true)
                if let started = process.startedAt {
                    DetailRow("Started", value: Display.dateTime(started, seconds: true), copyable: true)
                }
                if let path = process.executablePath { DetailRow("Executable", value: path, monospaced: true, copyable: true) }
                if process.arguments.count > 1 {
                    DetailRow("Arguments", value: process.arguments.dropFirst().joined(separator: " "), monospaced: true, copyable: true)
                }
            }

            if let quarantine = security.quarantineInfo(for: process) {
                QuarantineSection(info: quarantine)
            }

            connections(process.connections, of: process)

            if let path = process.executablePath {
                CodeDetailsSection(security: security, path: path)
                HStack {
                    Button("Reveal in Finder") { revealInFinder(path) }
                    Button("Copy path") { copyToPasteboard(path) }
                }
            }
            HStack {
                Button("Open Activity Monitor") { ProcessActions.openActivityMonitor() }
                if ProcessControl.canQuit(process) {
                    Button("Quit", role: .destructive) { ProcessActions.confirmAndQuit(process, security: security) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.hectorDanger)
                }
            }
        }
    }

    @ViewBuilder
    private func connections(_ connections: [SocketInfo]?, of process: RunningProcess) -> some View {
        Card {
            SectionHeader("Connections", systemImage: "network", style: .eyebrow)
            if let connections {
                if connections.isEmpty {
                    Text("None right now").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(connections.enumerated()), id: \.offset) { _, socket in
                        let blocked = socket.remoteAddress.map {
                            blocking.applied.blockReason(for: $0, country: monitor.country(for: $0)) != nil
                        } ?? false
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                            CopyableText(connectionLabel(socket), font: .system(.callout, design: .monospaced),
                                         id: "connection:\(connectionLabel(socket))")
                                .foregroundStyle(blocked ? Color.hectorDanger : Color.primary)
                            if let address = socket.remoteAddress, !address.isLocalOrPrivate {
                                blockButton(address, process: process)
                            }
                        }
                    }
                    if blocking.pendingChanges > 0 {
                        PendingBar(compact: true)
                    }
                }
            } else {
                Text("Readable through the helper only (another user's process).").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Blocks the remote address for every app, or takes the rule back; like the Connections
    /// screen, it only changes the draft until the user applies it.
    private func blockButton(_ address: IPAddress, process: RunningProcess) -> some View {
        let rule = blocking.addressRule(address)
        // Blocked by something else than this address's own rule: a network or a country. The
        // address's own rule, once switched off in the draft, is a pending change, not that.
        let enforced: Bool
        switch blocking.applied.blockReason(for: address, country: monitor.country(for: address)) {
        case .network(let cidr)?: enforced = cidr != CIDR(address)
        case .country?: enforced = true
        case nil: enforced = false
        }
        let label: String
        if rule == nil {
            label = enforced ? "Blocked by a wider rule" : "Block"
        } else {
            label = "Unblock"
        }
        return Button {
            blocking.toggleAddress(address, note: "\(process.displayName) · \(address.description)")
        } label: {
            Label(label, systemImage: rule == nil ? "nosign" : "arrow.uturn.backward")
                .labelStyle(.iconOnly)
                .foregroundStyle(rule == nil ? (enforced ? Color.secondary : Color.hectorDanger) : Color.hectorOK)
        }
        .buttonStyle(.borderless)
        .disabled(rule == nil && enforced)
        .help(rule == nil
              ? (enforced ? "\(address.description) is already blocked by a network or country rule (see Blocklists)."
                          : "Block \(address.description) for every app on this Mac. Nothing changes until you apply.")
              : (blocking.isPending(rule!) ? "Remove the pending rule for \(address.description)." : "Unblock \(address.description). Nothing changes until you apply."))
        .accessibilityLabel(rule == nil ? "Block \(address.description)" : "Unblock \(address.description)")
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
                DetailRow("On", value: Display.dateTime(date))
            }
            if let url = info.dataURL { DetailRow("From", value: url, monospaced: true, copyable: true) }
            if let origin = info.originURL { DetailRow("Page", value: origin, monospaced: true, copyable: true) }
            DetailRow("Opened", value: info.userApproved ? "Approved by the user in Gatekeeper" : "Not approved yet")
        }
    }
}

/// Actions on one process, shared by the row menu and the details panel.
@MainActor
enum ProcessActions {
    @ViewBuilder
    static func menu(for process: RunningProcess, security: SecurityController) -> some View {
        if let path = process.executablePath {
            Button("Reveal in Finder") { revealInFinder(path) }
            Button("Copy path") { copyToPasteboard(path) }
        }
        Button("Copy PID") { copyToPasteboard(String(process.pid)) }
        Divider()
        Button("Open Activity Monitor") { openActivityMonitor() }
        if ProcessControl.canQuit(process) {
            Button("Quit", role: .destructive) { confirmAndQuit(process, security: security) }
        }
    }

    /// Activity Monitor cannot be opened on a given process; the PID is in the row menu to search it.
    static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Asks first, then quits politely: an app through AppKit (it can ask to save its documents),
    /// anything else with SIGTERM. Only offered for the user's own processes (`ProcessControl.canQuit`).
    static func confirmAndQuit(_ process: RunningProcess, security: SecurityController) {
        let app = NSRunningApplication(processIdentifier: process.pid).flatMap { $0.activationPolicy == .regular ? $0 : nil }
        let alert = NSAlert()
        alert.messageText = "Quit \u{201C}\(process.name)\u{201D}?"
        var details = ["PID \(process.pid)" + (process.appName.map { $0 != process.name ? ", part of \($0)" : "" } ?? "") + "."]
        if app != nil {
            details.append("It is asked to quit as from its own menu, so it can offer to save open documents.")
        } else {
            details.append("It is sent a request to quit (SIGTERM), as `kill` does. Unsaved work in it may be lost, and macOS may start it again if it runs as a background service.")
        }
        alert.informativeText = details.joined(separator: " ")
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            if let app {
                try ProcessControl.verify(process)
                app.terminate()
            } else {
                try ProcessControl.terminate(process)
            }
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Hector could not quit \u{201C}\(process.name)\u{201D}"
            failure.informativeText = (error as? ProcessControl.Refusal)?.description ?? error.localizedDescription
            failure.runModal()
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await security.refreshProcesses()
        }
    }
}
