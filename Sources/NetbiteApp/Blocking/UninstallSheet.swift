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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.netbiteBlock)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Netbite").font(.title2.bold())
                    Text("Removes Netbite and everything it created on this Mac.").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Every blocking rule: the pf anchor and the Netbite section of /etc/hosts", systemImage: "nosign")
                Label("The helper, its LaunchDaemon, its data, its logs and its authorization right", systemImage: "gearshape.2")
                Label("Your blocklist, the country database, preferences, caches and saved window state", systemImage: "folder")
                Label("The VirusTotal API key in your Keychain, if you saved one", systemImage: "key")
                if Uninstaller.appBundle != nil {
                    Label("Netbite.app itself, moved to the Trash", systemImage: "app.dashed")
                }
            }
            .font(.callout)

            DisclosureGroup("Files that will be removed (\(systemItems.count + userItems.count))") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(systemItems, id: \.self) { Text($0) }
                    ForEach(userItems, id: \.self) { Text($0.path) }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            if !systemItems.isEmpty {
                Text("macOS will ask for an administrator password to remove the system part.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.netbiteBlock)
                    .textSelection(.enabled)
            }

            HStack {
                if phase == .working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase == .working)
                Button("Uninstall Netbite", role: .destructive) { Task { await uninstall() } }
                    .disabled(phase == .working)
            }
        }
        .padding(24)
        .frame(width: 560)
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
