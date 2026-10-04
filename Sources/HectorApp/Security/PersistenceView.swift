import HectorCore
import SwiftUI

extension PersistenceItem.Category {
    var symbol: String {
        switch self {
        case .launchAgent: "person.badge.clock"
        case .launchDaemon: "gearshape.2"
        case .loginItem: "person.crop.circle.badge.checkmark"
        case .backgroundTask: "clock.arrow.circlepath"
        case .cronJob: "calendar.badge.clock"
        case .periodicScript: "calendar"
        case .systemExtension: "puzzlepiece.extension"
        case .kernelExtension: "cpu"
        case .configurationProfile: "doc.badge.gearshape"
        case .browserExtension: "safari"
        case .other: "questionmark.folder"
        }
    }
}

extension PersistenceItem.Scope {
    var label: String {
        switch self {
        case .user: "User"
        case .system: "System"
        case .apple: "Apple"
        }
    }
}

/// Everything configured to start automatically, in the spirit of KnockKnock.
struct PersistenceView: View {
    @Environment(SecurityController.self) private var security
    @Environment(WindowState.self) private var state

    var body: some View {
        @Bindable var state = state
        let items = visibleItems
        VStack(spacing: 0) {
            header(items: items)
            Divider()
            if security.persistence == nil {
                EmptyStateView(security.isScanningPersistence ? "Hector is looking around…" : "Not scanned yet",
                               systemImage: "magnifyingglass",
                               message: "Launch agents and daemons, login items, cron jobs, extensions and profiles. Hector only reads them; nothing is ever run.") {
                    if !security.isScanningPersistence {
                        Button("Scan") { Task { await security.scanPersistence() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .canvasBackground()
            } else if items.isEmpty {
                EmptyStateView("Nothing matches", systemImage: "sparkle.magnifyingglass",
                               message: "No item matches “\(state.search)”.", tint: .hectorNeutral)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .canvasBackground()
            } else {
                list(items)
            }
        }
        .fillsSplitPane()
        .inspector(isPresented: $state.showInspector) {
            PersistenceDetailView(security: security, item: selectedItem)
                .fillsSplitPane()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .task {
            if security.persistence == nil { await security.scanPersistence() }
        }
    }

    private func header(items: [PersistenceItem]) -> some View {
        @Bindable var security = security
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            ScreenHeader("What starts by itself", subtitle: summary(items), systemImage: "arrow.triangle.2.circlepath",
                         tint: .hectorInfo, pinned: true) {
                Toggle("Show Apple items", isOn: $security.includeAppleItems)
                    .toggleStyle(.checkbox)
                    .onChange(of: security.includeAppleItems) { Task { await security.scanPersistence() } }
                checkAllButton(items)
                Button {
                    Task { await security.scanPersistence() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(security.isScanningPersistence)
            }
            ForEach(sourceNotes, id: \.self) { note in
                Banner(note.title, message: note.message, kind: note.kind)
                    .padding(.horizontal, Spacing.xl)
            }
        }
        .padding(.bottom, sourceNotes.isEmpty ? 0 : Spacing.sm)
        .background(Color.surfaceCanvas)
    }

    @ViewBuilder
    private func checkAllButton(_ items: [PersistenceItem]) -> some View {
        if security.isCheckingAll {
            Button("Stop VirusTotal") { security.cancelVirusTotal() }
        } else {
            Button {
                security.checkAllVirusTotal(paths: items.filter { $0.scope != .apple }.compactMap(SecurityController.codePath(of:)))
            } label: {
                Label("Check all with VirusTotal", systemImage: "shield.lefthalf.filled")
            }
            .disabled(!security.hasAPIKey)
            .help(security.hasAPIKey ? "Look up every third-party item (hashes only, 4 per minute)"
                                     : "Add your VirusTotal API key in Settings (⌘,) first")
        }
    }

    private func list(_ items: [PersistenceItem]) -> some View {
        @Bindable var state = state
        let categories = PersistenceItem.Category.allCases.filter { category in items.contains { $0.category == category } }
        return List(selection: $state.selectedPersistenceItem) {
            ForEach(categories, id: \.self) { category in
                Section {
                    ForEach(items.filter { $0.category == category }) { item in
                        PersistenceRow(security: security, item: item).tag(item.id)
                    }
                } header: {
                    SectionHeader(category.title, systemImage: category.symbol, style: .eyebrow)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .canvasBackground()
    }

    private var visibleItems: [PersistenceItem] {
        let items = security.persistence?.items ?? []
        let query = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { item in
            [item.label, item.executablePath ?? "", item.configurationPath ?? "", item.teamIdentifier ?? "",
             item.owningBundleIdentifier ?? "", item.category.title]
                .contains { $0.lowercased().contains(query) }
        }
    }

    private var selectedItem: PersistenceItem? {
        guard let id = state.selectedPersistenceItem else { return nil }
        return security.persistence?.items.first { $0.id == id }
    }

    private struct SourceNote: Hashable {
        var title: String
        var message: String
        var kind: StatusKind
    }

    private var sourceNotes: [SourceNote] {
        var notes = (security.persistence?.sources ?? []).flatMap { source in
            source.notes.map { note in
                note.hasPrefix("needs the helper")
                    ? SourceNote(title: "\(source.name) need the helper",
                                 message: "Install it from Blocklists: listing them needs root.", kind: .info)
                    : SourceNote(title: source.name, message: note, kind: .warning)
            }
        }
        if let issue = security.persistenceHelperIssue {
            notes.append(SourceNote(title: "The helper could not list login items",
                                    message: "\(issue) Updating the helper from Blocklists fixes an older one.", kind: .warning))
        }
        return notes
    }

    private func summary(_ items: [PersistenceItem]) -> String {
        guard let report = security.persistence else { return "Scanning…" }
        let unsigned = items.compactMap { security.signature(of: SecurityController.codePath(of: $0)) }
            .filter(\.trustLevel.isConcerning).count
        let noted = items.filter { !$0.notes.isEmpty }.count
        let scanned = Display.time(report.scannedAt)
        return "\(items.count) items · \(unsigned) unsigned or ad hoc · \(noted) with notes · scanned at \(scanned)"
    }
}

private struct PersistenceRow: View {
    let security: SecurityController
    let item: PersistenceItem

    var body: some View {
        let path = SecurityController.codePath(of: item)
        HStack(spacing: 10) {
            PathIcon(path: item.owningBundlePath ?? path, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label).fontWeight(.medium).lineLimit(1)
                    if item.isDisabled == true {
                        Text("Disabled").font(.caption2).foregroundStyle(.secondary)
                    }
                    if item.isInert {
                        Text("Inert").font(.caption2).foregroundStyle(.secondary)
                    }
                    if OwnHelper.isOwnHelper(item) {
                        let verdict = OwnHelper.verdict()
                        StatusPill("Hector", kind: verdict.isExpected ? .ok : .warning, showsIcon: false, size: .small)
                            .help(verdict.text)
                    }
                    if !item.notes.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.hectorWarning)
                            .help(item.notes.joined(separator: "\n"))
                    }
                }
                Text(path ?? item.configurationPath ?? "–")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            StatusPill(item.scope.label, kind: item.scope == .user ? .info : .neutral, showsIcon: false, size: .small)
                .frame(width: 64, alignment: .leading)
            SignatureBadge(security: security, path: path).frame(width: 120, alignment: .leading)
            VirusTotalBadge(security: security, path: path).frame(width: 80, alignment: .leading)
        }
        .padding(.vertical, 2)
        // Present, but launchd ignores it: keep it visible without drawing the eye.
        .opacity(item.isInert ? 0.5 : 1)
    }
}

struct PersistenceDetailView: View {
    let security: SecurityController
    let item: PersistenceItem?

    var body: some View {
        if let item {
            ScrollView {
                content(item)
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .canvasBackground()
        } else {
            EmptyStateView("No item selected", systemImage: "list.bullet.rectangle",
                           message: "Pick an item to see what it runs and who signed it.", compact: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ item: PersistenceItem) -> some View {
        let path = SecurityController.codePath(of: item)
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .top, spacing: Spacing.md) {
                PathIcon(path: item.owningBundlePath ?? path, size: 40)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    SectionHeader(item.category.title, style: .eyebrow)
                    Text(item.label).font(Font.sectionTitle).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    StatusPill("\(item.scope.label) item", kind: item.scope == .user ? .info : .neutral, showsIcon: false, size: .small)
                }
            }

            if let inert = item.details["inert"] {
                Banner("Inert: \(inert). Safe to leave or delete.", kind: .info)
            }
            if OwnHelper.isOwnHelper(item) {
                let verdict = OwnHelper.verdict()
                Banner(verdict.text, kind: verdict.isExpected ? .info : .warning)
            }
            if let launcher = item.details["launcher"] {
                Banner("Started through \(launcher); the signature shown is the app it opens.", kind: .info)
            }
            ForEach(item.notes, id: \.self) { note in
                Banner(note, kind: .warning)
            }

            Card {
                SectionHeader("Details", systemImage: "list.bullet.rectangle", style: .eyebrow)
                if let path { DetailRow("Runs") { pathText(path) } }
                if let configuration = item.configurationPath { DetailRow("Declared in") { pathText(configuration) } }
                if item.arguments.count > 1 {
                    DetailRow("Arguments", value: item.arguments.dropFirst().joined(separator: " "), monospaced: true)
                }
                if let runAtLoad = item.runAtLoad { DetailRow("Run at load", value: runAtLoad ? "Yes" : "No") }
                if let keepAlive = item.keepAlive { DetailRow("Keep alive", value: keepAlive ? "Yes" : "No") }
                if let disabled = item.isDisabled { DetailRow("Enabled", value: disabled ? "No" : "Yes") }
                if let bundle = item.owningBundleIdentifier { DetailRow("App", value: bundle) }
                if let modified = item.modifiedAt {
                    DetailRow("Modified", value: Display.dateTime(modified))
                }
                ForEach(item.details.keys.sorted().filter { $0 != "inert" }, id: \.self) { key in
                    DetailRow(key.capitalized, value: item.details[key] ?? "")
                }
            }

            if let path {
                CodeDetailsSection(security: security, path: path)
                HStack {
                    Button("Reveal in Finder") { revealInFinder(path) }
                    Button("Copy path") { copyToPasteboard(path) }
                }
            }
        }
    }

    private func pathText(_ path: String) -> some View {
        Text(path).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
