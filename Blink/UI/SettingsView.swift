import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            NavigationLink { LogsView() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
            Section("About") {
                LabeledContent("App", value: "Blink")
                LabeledContent("Tunnel", value: "WireGuard + Free TURN")
                LabeledContent("Minimum iOS", value: "16.0")
            }
            Section { Text("Secrets remain in the shared iOS Keychain and are never included in exported JSON or logs.").foregroundStyle(.secondary) }
        }.navigationTitle("Settings")
    }
}
