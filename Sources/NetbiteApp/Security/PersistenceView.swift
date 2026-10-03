import NetbiteCore
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
                ContentUnavailableView {
                    Label(security.isScanningPersistence ? "Scanning…" : "Not scanned yet", systemImage: "magnifyingglass")
                } description: {
                    Text("Launch agents and daemons, login items, cron jobs, extensions and profiles. Nothing found is run.")
                } actions: {
                    if !security.isScanningPersistence {
                        Button("Scan") { Task { await security.scanPersistence() } }
                    }
                }
            } else if items.isEmpty {
                ContentUnavailableView.search(text: state.search)
            } else {
                list(items)
            }
        }
        .inspector(isPresented: $state.showInspector) {
            PersistenceDetailView(item: selectedItem)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .task {
            if security.persistence == nil { await security.scanPersistence() }
        }
    }

    private func header(items: [PersistenceItem]) -> some View {
        @Bindable var security = security
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What starts automatically").font(.headline)
                    Text(summary(items)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
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
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                        PersistenceRow(item: item).tag(item.id)
                    }
                } header: {
                    Label(category.title, systemImage: category.symbol).font(.headline)
                }
            }
        }
        .listStyle(.inset)
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

    private var sourceNotes: [String] {
        var notes = (security.persistence?.sources ?? []).flatMap { source in
            source.notes.map { "\(source.name): \($0)" }
        }
        if let issue = security.persistenceHelperIssue {
            notes.append("The helper could not list login items: \(issue) Reinstalling the helper from Blocklists updates it.")
        }
        return notes
    }

    private func summary(_ items: [PersistenceItem]) -> String {
        guard let report = security.persistence else { return "Scanning…" }
        let unsigned = items.compactMap { security.signature(of: SecurityController.codePath(of: $0)) }
            .filter(\.trustLevel.isConcerning).count
        let noted = items.filter { !$0.notes.isEmpty }.count
        let scanned = report.scannedAt.formatted(date: .omitted, time: .shortened)
        return "\(items.count) items · \(unsigned) unsigned or ad hoc · \(noted) with notes · scanned at \(scanned)"
    }
}

private struct PersistenceRow: View {
    let item: PersistenceItem

    var body: some View {
        let path = SecurityController.codePath(of: item)
        HStack(spacing: 10) {
            PathIcon(path: item.owningBundlePath ?? path, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label).fontWeight(.medium).lineLimit(1)
                    if item.isDisabled == true {
                        Text("Disabled").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !item.notes.isEmpty {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
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
            Text(item.scope.label).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            SignatureBadge(path: path).frame(width: 120, alignment: .leading)
            VirusTotalBadge(path: path).frame(width: 80, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

struct PersistenceDetailView: View {
    let item: PersistenceItem?

    var body: some View {
        if let item {
            ScrollView {
                content(item)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No item selected", systemImage: "list.bullet.rectangle",
                                   description: Text("Pick an item to see what it runs and who signed it."))
        }
    }

    @ViewBuilder
    private func content(_ item: PersistenceItem) -> some View {
        let path = SecurityController.codePath(of: item)
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(item.category.title)
                Text(item.label).font(.title2.bold()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("\(item.scope.label) item").font(.callout).foregroundStyle(.secondary)
            }

            if !item.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.notes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                if let path { row("Runs") { pathText(path) } }
                if let configuration = item.configurationPath { row("Declared in") { pathText(configuration) } }
                if item.arguments.count > 1 {
                    row("Arguments") { Text(item.arguments.dropFirst().joined(separator: " ")).monospaced().textSelection(.enabled) }
                }
                if let runAtLoad = item.runAtLoad { row("Run at load") { Text(runAtLoad ? "Yes" : "No") } }
                if let keepAlive = item.keepAlive { row("Keep alive") { Text(keepAlive ? "Yes" : "No") } }
                if let disabled = item.isDisabled { row("Enabled") { Text(disabled ? "No" : "Yes") } }
                if let bundle = item.owningBundleIdentifier { row("App") { Text(bundle).textSelection(.enabled) } }
                if let modified = item.modifiedAt { row("Modified") { Text(modified.formatted(date: .abbreviated, time: .shortened)) } }
                ForEach(item.details.keys.sorted(), id: \.self) { key in
                    row(key.capitalized) { Text(item.details[key] ?? "").textSelection(.enabled) }
                }
            }
            .font(.callout)

            if let path {
                CodeDetailsSection(path: path)
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

    private func row<Content: View>(_ label: String, @ViewBuilder _ value: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            value()
        }
    }
}
