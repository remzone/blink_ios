import SwiftUI

struct XrayConnectionView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var xray: XrayVPNController
    @State private var link = ""
    var body: some View {
        Form {
            Section("Direct VLESS") {
                SecureField("vless://…", text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save securely and connect") {
                    let value = link
                    Task { await xray.connect(link: value, secrets: container.secretStore) }
                }.disabled(link.isEmpty || xray.busy)
                Text("Supports basic TCP or XHTTP with TLS/REALITY. Extended XHTTP extra/downloadSettings are rejected, not silently removed. Paste an individual VLESS link from your panel subscription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tunnel") {
                Text(xray.status)
                if let error = xray.errorMessage { Text(error).foregroundStyle(.red) }
                Button("Check transport status") { Task { await xray.refreshTransportStatus() } }
                Button("Disconnect", role: .destructive) { xray.disconnect() }
            }
            Section {
                Text("Native bridge source is implemented; this revision has not been compiled for iOS or tested on an iPhone. A system VPN status is not proof of internet connectivity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Xray")
            .onDisappear { link = "" }
    }
}
