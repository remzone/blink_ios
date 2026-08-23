import Foundation
import NetworkExtension

@MainActor
protocol VPNService: AnyObject {
    var state: VPNState { get }
    var stateChanges: AsyncStream<VPNState> { get }
    func connect(profile: VPNProfile, secrets: ProfileSecrets) async throws
    func disconnect() async
}

enum VPNServiceError: LocalizedError {
    case missingPrivateKey, missingPeerPublicKey, configurationNotSaved
    var errorDescription: String? {
        switch self {
        case .missingPrivateKey: "Add a WireGuard private key to the selected profile."
        case .missingPeerPublicKey: "Add the WireGuard server public key to the selected profile."
        case .configurationNotSaved: "The system VPN configuration could not be saved."
        }
    }
}

@MainActor
final class SystemVPNService: VPNService {
    private(set) var state: VPNState = .disconnected { didSet { continuation?.yield(state) } }
    private var continuation: AsyncStream<VPNState>.Continuation?
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var lastCoreState: String?
    private var lastSystemStatus: NEVPNStatus?
    private let logStore: LogStore
    lazy var stateChanges = AsyncStream<VPNState> { self.continuation = $0; $0.yield(self.state) }

    init(logStore: LogStore) {
        self.logStore = logStore
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.consume(connection.status) }
        }
        Task { await restoreManager() }
    }

    deinit { if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) } }

    func connect(profile: VPNProfile, secrets: ProfileSecrets) async throws {
        guard !secrets.wireGuardPrivateKey.isEmpty else { throw VPNServiceError.missingPrivateKey }
        guard !profile.wireGuard.publicKey.isEmpty else { throw VPNServiceError.missingPeerPublicKey }
        state = .connecting
        let manager = try await configuredManager(profile: profile)
        self.manager = manager
        do {
            try manager.connection.startVPNTunnel(options: ["activationAttemptId": UUID().uuidString as NSString])
            logStore.add(.info, source: "VPN", message: "System tunnel start requested")
        } catch {
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    func disconnect() async {
        state = .disconnecting
        manager?.connection.stopVPNTunnel()
        logStore.add(.info, source: "VPN", message: "System tunnel stop requested")
    }

    func metrics() async -> TunnelMetrics? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data([0])) { data in
                    let value = data.flatMap { try? JSONDecoder().decode(TunnelMetrics.self, from: $0) }
                    Task { @MainActor in
                        if let value, value.state != self.lastCoreState {
                            self.lastCoreState = value.state
                            self.logStore.add(.info, source: "FreeTurn", message: "State: \(value.state)")
                        }
                    }
                    continuation.resume(returning: value)
                }
            } catch { continuation.resume(returning: nil) }
        }
    }

    private func restoreManager() async {
        do {
            manager = try await loadManagers().first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == SharedConstants.tunnelBundleIdentifier }
            if let manager { consume(manager.connection.status) }
        } catch { logStore.add(.warning, source: "VPN", message: "Unable to load system VPN configuration") }
    }

    private func configuredManager(profile: VPNProfile) async throws -> NETunnelProviderManager {
        let existing = try await loadManagers().first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == SharedConstants.tunnelBundleIdentifier }
        let manager = existing ?? NETunnelProviderManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = SharedConstants.tunnelBundleIdentifier
        tunnelProtocol.serverAddress = profile.server
        tunnelProtocol.providerConfiguration = [SharedConstants.profileIDKey: profile.id.uuidString]
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = "Blink — \(profile.name)"
        manager.isEnabled = true
        try await save(manager)
        try await load(manager)
        guard manager.isEnabled else { throw VPNServiceError.configurationNotSaved }
        return manager
    }

    private func consume(_ status: NEVPNStatus) {
        if status != lastSystemStatus {
            lastSystemStatus = status
            logStore.add(.info, source: "WireGuard", message: "System status: \(status.safeName)")
        }
        switch status {
        case .invalid, .disconnected: state = .disconnected
        case .connecting, .reasserting: state = .connecting
        case .connected: state = .connected(since: manager?.connection.connectedDate ?? .now)
        case .disconnecting: state = .disconnecting
        @unknown default: state = .failed(message: "Unknown VPN status")
        }
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { values, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: values ?? []) }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func load(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

private extension NEVPNStatus {
    var safeName: String {
        switch self {
        case .invalid: "invalid"
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reasserting: "reasserting"
        case .disconnecting: "disconnecting"
        @unknown default: "unknown"
        }
    }
}
