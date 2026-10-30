import SwiftUI

struct StandardSubscriptionView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var xray: XrayVPNController
    @State private var url = ""
    @State private var nodes: [StandardSubscriptionNode] = []
    @State private var message: String?
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var task: Task<Void, Never>?
    private let credentialID = UUID(uuidString: "e89994b2-93d9-43a9-b67e-73d69315205f")!

    var body: some View {
        List {
            Section("Standard 3x-ui subscription") {
                SecureField("HTTPS subscription URL", text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(loading)
                Button(loading ? "Loading…" : "Load and save URL securely") { load() }
                    .disabled(loading || url.isEmpty)
                Button("Forget subscription", role: .destructive) { forget() }
                Text("Plain URI-list and base64 subscriptions are supported. Each unsupported node is shown with a reason; no connection settings are silently discarded.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            if !nodes.isEmpty {
                Section("Nodes") {
                    ForEach(nodes) { node in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(node.name)
                            if let profile = node.profile {
                                Text("VLESS / \(profile.network) / \(profile.security)").font(.caption)
                                Button("Connect") {
                                    Task { await xray.connect(profile: profile, secrets: container.secretStore) }
                                }.disabled(xray.busy)
                            } else {
                                Text(node.rejection ?? "Unsupported node.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Tunnel") {
                Text(xray.status)
                if let error = xray.errorMessage { Text(error).foregroundStyle(.red) }
                Button("Check transport status") { Task { await xray.refreshTransportStatus() } }
                Button("Disconnect", role: .destructive) { xray.disconnect() }
            }
        }.navigationTitle("3x-ui subscription")
            .onAppear {
                guard url.isEmpty else { return }
                do { url = try container.secretStore.read(profileID: credentialID, kind: .standardSubscriptionURL) ?? "" }
                catch { message = "Could not read the saved URL from Keychain." }
            }
            .onDisappear { cancel(); url = ""; nodes = [] }
    }

    private func load() {
        cancel()
        let id = UUID(); requestID = id
        let requestedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        loading = true; nodes = []; message = nil
        task = Task { @MainActor in
            defer { if requestID == id { loading = false } }
            do {
                let data = try await SecureSubscriptionHTTP().fetch(requestedURL)
                let result = try StandardSubscription.parse(data)
                try Task.checkCancellation()
                guard requestID == id else { return }
                try container.secretStore.save(requestedURL, profileID: credentialID, kind: .standardSubscriptionURL)
                nodes = result; url = requestedURL
                let accepted = result.filter { $0.profile != nil }.count
                message = "\(accepted) supported, \(result.count - accepted) rejected."
            } catch is CancellationError {
            } catch let error as SubscriptionError {
                if requestID == id { message = error.localizedDescription }
            } catch {
                if requestID == id { message = "Could not store the subscription URL securely." }
            }
        }
    }
    private func cancel() { requestID = UUID(); task?.cancel(); task = nil; loading = false }
    private func forget() {
        cancel(); nodes = []; url = ""
        do { try container.secretStore.delete(profileID: credentialID); message = "Saved subscription removed." }
        catch { message = "Could not remove the subscription from Keychain." }
    }
}
