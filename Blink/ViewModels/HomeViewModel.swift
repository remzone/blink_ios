import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var state: VPNState = .disconnected
    @Published var errorMessage: String?
    private var observation: Task<Void, Never>?

    func observe(_ service: VPNService) {
        guard observation == nil else { return }
        observation = Task { for await value in service.stateChanges { state = value } }
    }

    func toggle(container: AppContainer) async {
        if case .connected = state { await container.vpnService.disconnect(); return }
        guard let profile = container.profileStore.selectedProfile else {
            errorMessage = "Create and select a VPN profile first."; return
        }
        do {
            let secrets = ProfileSecrets(
                wireGuardPrivateKey: try container.secretStore.read(profileID: profile.id, kind: .wireGuardPrivateKey) ?? "",
                obfuscationKey: try container.secretStore.read(profileID: profile.id, kind: .obfuscationKey) ?? "")
            try await container.vpnService.connect(profile: profile, secrets: secrets)
        } catch {
            errorMessage = error.localizedDescription
            container.logStore.add(.error, source: "VPN", message: error.localizedDescription)
        }
    }
}
