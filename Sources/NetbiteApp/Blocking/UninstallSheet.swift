import AppKit
import SwiftUI

/// Confirms, then removes Netbite and everything it created.
struct UninstallSheet: View {
    @Environment(WindowState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private var phase: UninstallPhase { state.uninstallPhase }

    var body: some View {
        let systemItems = Uninstaller.systemItems
        let userItems = Uninstaller.userItems
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.md) {
                SymbolTile("trash", tint: .hexDanger, size: 48)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Uninstall Netbite")
                        .font(.displayTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Removes Netbite and everything it created on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            Card(spacing: 10) {
                SectionHeader("What goes away", style: .eyebrow)
                RemovalItem("Every blocking rule: the pf anchor and the Netbite section of /etc/hosts", systemImage: "nosign")
                RemovalItem("The helper, its LaunchDaemon, its data, its logs and its authorization right", systemImage: "gearshape.2")
                RemovalItem("Your blocklist, the country database, preferences, caches and saved window state", systemImage: "folder")
                RemovalItem("The VirusTotal API key in your Keychain, if you saved one", systemImage: "key")
                if Uninstaller.appBundle != nil {
                    RemovalItem("Netbite.app itself, moved to the Trash", systemImage: "app.dashed")
                }
            }

            DisclosureGroup("Files that will be removed (\(systemItems.count + userItems.count))") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(systemItems, id: \.self) { Text($0) }
                    ForEach(userItems, id: \.self) { Text($0.path) }
                }
                .font(.dataMonoCaption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .insetSurface()
                .padding(.top, Spacing.xs)
            }

            if !systemItems.isEmpty {
                Label("macOS will ask for an administrator password to remove the system part.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = phase {
                Banner("Uninstall did not finish", message: message, kind: .danger)
            }

            HStack {
                if phase == .working {
                    ProgressView().controlSize(.small)
                    Text("Removing…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase == .working)
                Button("Uninstall Netbite", role: .destructive) { Task { await uninstall() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.hexDangerTint)
                    .disabled(phase == .working)
                    .help("There is no undo: rules, helper and data are deleted")
            }
        }
        .padding(Spacing.xl + 4)
        .frame(width: 560)
        .background(Color.surfaceCanvas)
        .onAppear { if state.uninstallPhase != .working { state.uninstallPhase = .confirm } }
    }

    private func uninstall() async {
        state.uninstallPhase = .working
        switch await Uninstaller.uninstall() {
        case .done:
            Uninstaller.quitLeavingNoTrace()
        case .cancelled:
            state.uninstallPhase = .confirm
        case .failed(let message):
            state.uninstallPhase = .failed(message)
        }
    }
}

/// One line of what the uninstaller removes.
private struct RemovalItem: View {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.hexDanger)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
