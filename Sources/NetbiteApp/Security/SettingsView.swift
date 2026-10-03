import NetbiteCore
import SwiftUI

/// The app's Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            VirusTotalSettings()
                .tabItem { Label("VirusTotal", systemImage: "shield.lefthalf.filled") }
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
                        Label("Stored in your Keychain", systemImage: "key.fill").foregroundStyle(Color.hexOK)
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
                    Text(message).font(.caption).foregroundStyle(Color.hexDanger)
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
