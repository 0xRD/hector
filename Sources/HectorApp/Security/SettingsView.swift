import HectorCore
import SwiftUI

/// The app's Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
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
