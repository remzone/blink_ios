import Foundation
import NetworkExtension
import WireGuardKit
import Mobile
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let freeTurn = FreeTurnManager()
    private var startTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.blink.tunnel.PacketTunnel", category: "Tunnel")
    private lazy var adapter = WireGuardAdapter(with: self) { [weak self] level, _ in
        switch level {
        case .verbose: self?.logger.debug("WireGuard event")
        case .error: self?.logger.error("WireGuard error event")
        }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        startTask = Task {
            do {
                let profile = try loadProfile()
                let secretStore = KeychainSecretStore()
                guard let privateKey = try secretStore.read(profileID: profile.id, kind: .wireGuardPrivateKey), !privateKey.isEmpty else {
                    throw TunnelError.missingWireGuardPrivateKey
                }
                let obfuscationKey = try secretStore.read(profileID: profile.id, kind: .obfuscationKey) ?? ""
                try await freeTurn.start(profile: profile, obfuscationKey: obfuscationKey)
                let configuration = try makeTunnelConfiguration(profile: profile, privateKey: privateKey)
                try await startWireGuard(configuration)
                logger.info("Tunnel started")
                completionHandler(nil)
            } catch {
                freeTurn.stop()
                logger.error("Tunnel start failed")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        startTask?.cancel()
        adapter.stop { [freeTurn] _ in
            freeTurn.stop()
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }

    override func wake() {
        MobileWake()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(try? JSONEncoder().encode(freeTurn.metrics()))
    }

    private func loadProfile() throws -> VPNProfile {
        guard let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
              let value = protocolConfiguration.providerConfiguration?[SharedConstants.profileIDKey] as? String,
              let id = UUID(uuidString: value) else { throw TunnelError.invalidProviderConfiguration }
        return try SharedProfileReader.profile(id: id)
    }

    private func makeTunnelConfiguration(profile: VPNProfile, privateKey: String) throws -> TunnelConfiguration {
        guard let privateKeyData = Data(base64Encoded: privateKey), let key = PrivateKey(rawValue: privateKeyData) else {
            throw TunnelError.invalidWireGuardPrivateKey
        }
        guard let publicKeyData = Data(base64Encoded: profile.wireGuard.publicKey), let publicKey = PublicKey(rawValue: publicKeyData) else {
            throw TunnelError.invalidPeerPublicKey
        }
        var interface = InterfaceConfiguration(privateKey: key)
        interface.addresses = try profile.wireGuard.address.split(separator: ",").map {
            let value = $0.trimmingCharacters(in: .whitespaces)
            guard let range = IPAddressRange(from: value) else { throw TunnelError.invalidAddress(value) }
            return range
        }
        if !profile.wireGuard.dns.isEmpty {
            interface.dns = try profile.wireGuard.dns.split(separator: ",").map {
                let value = $0.trimmingCharacters(in: .whitespaces)
                guard let server = DNSServer(from: value) else { throw TunnelError.invalidDNS(value) }
                return server
            }
        }
        interface.mtu = profile.wireGuard.mtu

        var peer = PeerConfiguration(publicKey: publicKey)
        peer.endpoint = Endpoint(from: "127.0.0.1:\(profile.freeTurn.listenPort)")
        peer.allowedIPs = try profile.wireGuard.allowedIPs.map {
            guard let range = IPAddressRange(from: $0) else { throw TunnelError.invalidAllowedIP($0) }
            return range
        }
        peer.persistentKeepAlive = profile.wireGuard.persistentKeepAlive
        return TunnelConfiguration(name: profile.name, interface: interface, peers: [peer])
    }

    private func startWireGuard(_ configuration: TunnelConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: configuration) { error in
                if let error { continuation.resume(throwing: TunnelError.wireGuard(error.localizedDescription)) }
                else { continuation.resume() }
            }
        }
    }
}
