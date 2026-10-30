import Foundation
import Combine
import NetworkExtension

@MainActor
final class XrayVPNController: ObservableObject {
    @Published private(set) var status = "Disconnected"
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    private var operation = UUID()
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private let credentialID = UUID(uuidString: "ea77c5bb-87aa-4363-8b94-3229302d1ccd")!

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor in
                guard let self, connection === self.manager?.connection else { return }
                self.consume(connection.status)
            }
        }
        Task { await restore() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func connect(link: String, secrets: SecretStore) async {
        do {
            let profile = try XrayProfile.parse(link)
            await connect(json: try profile.json(), mode: "direct", server: profile.address, secrets: secrets)
        } catch let error as XrayProfileError { errorMessage = error.localizedDescription }
        catch { errorMessage = "Unable to read the VLESS profile." }
    }

    func connect(profile: XrayProfile, secrets: SecretStore) async {
        do { await connect(json: try profile.json(), mode: "direct", server: profile.address, secrets: secrets) }
        catch { errorMessage = "Unable to encode the VLESS profile." }
    }

    func connect(profile: VokopSubscription.Profile, expiresAt: Int64, dnsServer: String, secrets: SecretStore) async {
        struct VKProfile: Encodable {
            let uuid: String; let peerHost: String; let peerPort: Int
            let vkCallURL: String; let streams: Int; let expiresAt: Int64; let dnsServer: String
        }
        guard expiresAt > Int64(Date().timeIntervalSince1970) else { errorMessage = "Subscription expired. Refresh it before connecting."; return }
        let value = VKProfile(uuid: profile.vless.uuid, peerHost: profile.turn.peer_host, peerPort: profile.turn.peer_port,
            vkCallURL: profile.turn.vk_call_url, streams: profile.turn.streams, expiresAt: expiresAt, dnsServer: dnsServer)
        do {
            let data = try JSONEncoder().encode(value)
            await connect(json: String(decoding: data, as: UTF8.self), mode: "vkturn", server: profile.turn.peer_host, secrets: secrets)
        } catch { errorMessage = "Unable to encode the subscription profile." }
    }

    private func connect(json: String, mode: String, server: String, secrets: SecretStore) async {
        guard !busy else { return }
        let attempt = UUID(); operation = attempt
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard operation == attempt else { return }
            let manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == SharedConstants.xrayTunnelBundleIdentifier } ?? NETunnelProviderManager()
            // Do not overwrite credentials underneath a running extension.
            guard [.invalid, .disconnected].contains(manager.connection.status) else {
                errorMessage = "Disconnect the current Xray tunnel before choosing another profile."; return
            }
            try secrets.save(json, profileID: credentialID, kind: .xrayProfile)
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = SharedConstants.xrayTunnelBundleIdentifier
            configuration.serverAddress = server
            configuration.providerConfiguration = [SharedConstants.profileIDKey: credentialID.uuidString, "mode": mode]
            manager.protocolConfiguration = configuration
            manager.localizedDescription = mode == "vkturn" ? "Blink — VLESS / VK TURN" : "Blink — VLESS / Xray"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            guard operation == attempt else { return }
            try await manager.loadFromPreferences()
            guard operation == attempt else { return }
            self.manager = manager
            try manager.connection.startVPNTunnel()
            consume(manager.connection.status)
        } catch { errorMessage = "Unable to save or start the VPN configuration. Check VPN permission and provisioning." }
    }

    func disconnect() {
        operation = UUID()
        manager?.connection.stopVPNTunnel()
        status = manager == nil ? "Disconnected" : "Disconnecting…"
    }

    func refreshTransportStatus() async {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reply = StatusReply(continuation)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                reply.finish()
            }
            do {
                try session.sendProviderMessage(Data([0])) { [weak self] data in
                    Task { @MainActor in
                        defer { reply.finish() }
                        guard reply.pending, let self, self.manager?.connection === session, session.status == .connected, let data,
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                              let engine = object["engine"] else { return }
                        switch engine {
                        case "ready": self.status = "VPN active · VK transport ready"
                        case "connecting": self.status = "VPN active · VK transport connecting"
                        case "captcha_required": self.status = "VK requires CAPTCHA. Disconnect and contact the administrator."
                        case "stopped": self.status = "Engine stopped — disconnect and refresh subscription"
                        default: self.status = "VPN active · Xray running (connectivity not verified)"
                        }
                    }
                }
            } catch { reply.finish() }
        }
    }

    private func restore() async {
        do {
            let restored = try await NETunnelProviderManager.loadAllFromPreferences().first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == SharedConstants.xrayTunnelBundleIdentifier
            }
            guard !busy, manager == nil else { return }
            manager = restored
            if let manager { consume(manager.connection.status) }
        } catch { errorMessage = "Unable to restore VPN preferences." }
    }
    private func consume(_ state: NEVPNStatus) {
        switch state {
        case .connected: status = "VPN active (connectivity not verified)"
        case .connecting, .reasserting: status = "Connecting…"
        case .disconnecting: status = "Disconnecting…"
        default: status = "Disconnected"
        }
    }
}

@MainActor
private final class StatusReply {
    private var continuation: CheckedContinuation<Void, Never>?
    var pending: Bool { continuation != nil }
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func finish() { continuation?.resume(); continuation = nil }
}
