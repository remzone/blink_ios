import SwiftUI

/// Preview is intentionally separate from connectable legacy WireGuard profiles.
struct SubscriptionView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var xray: XrayVPNController
    @AppStorage("vokop.bootstrapDNS") private var bootstrapDNS = "1.1.1.1"
    @State private var link = ""
    @State private var document: VokopSubscription?
    @State private var message: String?
    @State private var loading = false
    @State private var task: Task<Void, Never>?
    @State private var lastURL = ""
    @State private var highestRevision: Int64 = 0
    @State private var requestID = UUID()
    private let credentialID = UUID(uuidString: "57f8b06a-c211-4b4f-8525-14cb2e7a882e")!

    var body: some View {
        List {
            Section("Panel subscription") {
                TextField("VK bootstrap DNS IP", text: $bootstrapDNS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("VK bootstrap DNS queries go outside the VPN through this explicit resolver (default 1.1.1.1). Use an IPv4 or IPv6 address, not a hostname.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("HTTPS subscription link", text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(loading)
                Button(loading ? "Loading…" : "Save link and preview") { refresh() }
                    .disabled(loading || link.isEmpty)
                Button("Forget subscription", role: .destructive) { forget() }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            if let document {
                Section("Subscription preview") {
                    LabeledContent("Revision", value: String(document.revision))
                    LabeledContent("Expires", value: Date(timeIntervalSince1970: TimeInterval(document.expires_at)).formatted())
                    ForEach(document.profiles) { profile in
                        VStack(alignment: .leading) {
                            Text(profile.name.isEmpty ? profile.id : profile.name)
                            Button("Connect using VK TURN") {
                                Task { await xray.connect(profile: profile, expiresAt: document.expires_at, dnsServer: bootstrapDNS, secrets: container.secretStore) }
                            }.disabled(xray.busy)
                            Text("VLESS / VK TURN · \(profile.turn.peer_host):\(profile.turn.peer_port)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Connection support") {
                NavigationLink("Direct VLESS / XHTTP") { XrayConnectionView() }
                Text(xray.status)
                if let error = xray.errorMessage { Text(error).foregroundStyle(.red) }
                Button("Check transport status") { Task { await xray.refreshTransportStatus() } }
                Button("Disconnect Xray", role: .destructive) { xray.disconnect() }
                Text("Vokop profiles use a dedicated Xray extension, not the legacy WireGuard engine. Native source is implemented but iOS build and device validation remain pending.")
                Text("VK compatibility mode does not authenticate the DTLS server certificate; inner VLESS is not TLS-protected. It is not equivalent to authenticated end-to-end TLS. Use application HTTPS and review this limitation before production use.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Direct VLESS/XHTTP uses a separate 3x-ui subscription format; it is not accepted here.")
            }
            Section("Balance") {
                Text("Check /balance in your administrator’s Telegram bot. The panel does not yet expose a mobile account/balance API. Never enter an administrator password in this app.")
            }
        }
        .navigationTitle("Vokop")
        .onAppear {
            guard link.isEmpty else { return }
            do {
                let saved = try container.secretStore.read(profileID: credentialID, kind: .subscriptionURL) ?? ""
                if let state = try? JSONDecoder().decode(SavedVokopSubscription.self, from: Data(saved.utf8)) {
                    link = state.url; lastURL = state.url; highestRevision = state.highestRevision
                } else {
                    // One-time compatibility with the earlier URL-only Keychain value.
                    link = saved; lastURL = saved; highestRevision = 0
                }
            }
            catch { message = "Could not read the saved link from Keychain." }
        }
        .onDisappear {
            requestID = UUID(); task?.cancel(); task = nil; loading = false
            document = nil; link = ""; lastURL = ""
        }
    }

    private func refresh() {
        task?.cancel()
        let id = UUID(); requestID = id
        let requestedURL = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimumRevision = requestedURL == lastURL ? highestRevision : 0
        document = nil; message = nil; loading = true
        task = Task { @MainActor in
            defer { if requestID == id { loading = false } }
            do {
                _ = try VokopSubscriptionClient.validatedURL(requestedURL)
                let result = try await VokopSubscriptionClient().fetch(requestedURL, minimumRevision: minimumRevision)
                try Task.checkCancellation()
                guard requestID == id else { return }
                let state = SavedVokopSubscription(url: requestedURL, highestRevision: result.revision)
                let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
                try container.secretStore.save(encoded, profileID: credentialID, kind: .subscriptionURL)
                document = result; lastURL = requestedURL; link = requestedURL; highestRevision = result.revision
            } catch is CancellationError {
                // Dismissal/Forget must not repopulate a cleared screen.
            } catch let error as SubscriptionError {
                if requestID == id { message = error.localizedDescription }
            } catch {
                if requestID == id { message = "Could not save the link securely in Keychain." }
            }
        }
    }

    private func forget() {
        requestID = UUID(); task?.cancel(); task = nil
        document = nil; lastURL = ""; highestRevision = 0; link = ""; loading = false
        do {
            try container.secretStore.delete(profileID: credentialID)
            message = "Saved subscription removed."
        } catch { message = "Could not remove the saved subscription from Keychain." }
    }
}
