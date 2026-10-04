import AppKit
import HectorCore
import SwiftUI

/// The app's Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            VirusTotalSettings()
                .tabItem { Label("VirusTotal", systemImage: "shield.lefthalf.filled") }
            AboutHector()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

private struct VirusTotalSettings: View {
    @Environment(SecurityController.self) private var security
    @Environment(WindowState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                LabeledContent("API key") {
                    if security.hasAPIKey {
                        Label("Stored in your Keychain", systemImage: "key.fill").foregroundStyle(Color.hectorOK)
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                SecureField(security.hasAPIKey ? "Replace with a new key" : "Paste your key", text: $state.apiKeyDraft)
                    .onSubmit(save)
                HStack {
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!APIKeyStore.isValidVirusTotalKey(state.apiKeyDraft))
                    if security.hasAPIKey {
                        Button("Remove key", role: .destructive) { security.deleteKey() }
                    }
                    Spacer()
                    Link("Get a free key", destination: URL(string: "https://www.virustotal.com/gui/my-apikey")!)
                }
                if let message = security.keyMessage {
                    Text(message).font(.caption).foregroundStyle(Color.hectorDanger)
                }
            } header: {
                Text("VirusTotal")
            } footer: {
                Text("""
                Only SHA-256 hashes are sent, and only when you ask: never the files themselves. \
                The free tier allows 4 lookups per minute and 500 per day; results are cached for 7 days. \
                The key stays in your login Keychain.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { security.refreshKeyState() }
    }

    private func save() {
        if security.saveKey(state.apiKeyDraft) {
            // Never keep the key in memory longer than needed.
            state.apiKeyDraft = ""
        }
    }
}

/// Hector's data on this Mac, and the way out.
private struct GeneralSettings: View {
    @Environment(WindowState.self) private var state
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })) {
                    Text("Open Hector at login")
                    Text("Starts Hector when you log in, so the camera and microphone log covers the whole session.")
                }
                Toggle(isOn: Binding(get: { preferences.keepsRunningInMenuBar }, set: { preferences.keepsRunningInMenuBar = $0 })) {
                    Text("Keep running in the menu bar")
                    Text("Closing the window leaves Hector in the menu bar instead of quitting. At login it opens there, without a window.")
                }
                if loginItem.needsApproval {
                    LabeledContent("Switched off in System Settings") {
                        Button("Open Login Items") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Blocking does not depend on this: the helper enforces your rules from boot, even when Hector is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Self.dataFiles, id: \.name) { file in
                    LabeledContent(file.label) {
                        Text(Self.size(of: file.name) ?? "Not downloaded").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([LegacyMigration.userDataDirectory])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: LegacyMigration.userDataDirectory.path))
                }
            } header: {
                Text("Data on this Mac")
            } footer: {
                Text("DB-IP Lite databases (CC BY 4.0), downloaded when you ask and updated monthly. Every lookup stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Uninstall Hector…", role: .destructive, action: uninstall)
                } label: {
                    Text("Uninstall")
                    Text("Removes the helper, every rule, the databases, the API key and the app.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }

    private var loginItem: LoginItem { .shared }

    private static let dataFiles = [
        (label: "Countries", name: "dbip-country-lite.csv"),
        (label: "Network names", name: "dbip-asn-lite.csv"),
    ]

    private static func size(of name: String) -> String? {
        let url = LegacyMigration.userDataDirectory.appending(path: name)
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The confirmation sheet belongs to the main window: close Settings and bring that forward.
    private func uninstall() {
        NSApp.keyWindow?.close()
        NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Hector" }?.makeKeyAndOrderFront(nil)
        state.showUninstall = true
    }
}

/// Who Hector is, in a few lines: the wordmark, what it does and the version.
private struct AboutHector: View {
    var body: some View {
        VStack(spacing: Spacing.lg) {
            HectorWordmark(size: 30)
            VStack(spacing: Spacing.xs) {
                Text("Hector holds the gate for your Mac.")
                    .font(.sectionTitle)
                Text("It watches what connects, what starts by itself and what runs, and tells you plainly when something is worth a look.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 400)
            VStack(spacing: Spacing.xxs) {
                Text("Version \(HectorVersion.current) · open source")
                    .monospacedDigit()
                Text("Netbite, its network module, was the name of the app up to 0.3.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}
