import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let profileStore: ProfileStore
    let secretStore: SecretStore
    let vpnService: VPNService
    let logStore: LogStore

    init() {
        let logs = LogStore()
        self.logStore = logs
        self.profileStore = ProfileStore(logStore: logs)
        self.secretStore = KeychainSecretStore()
        self.vpnService = SystemVPNService(logStore: logs)
    }
}
