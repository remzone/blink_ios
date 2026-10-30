import Foundation
import NetworkExtension
import BlinkCore
import Darwin

/// Separate extension process: never links WireGuardKit or legacy Mobile.
final class XrayPacketTunnelProvider: NEPacketTunnelProvider, MobilePacketWriterProtocol {
    private let ioQueue = DispatchQueue(label: "com.blink.xray.packets")
    private let protector = XraySocketProtector()
    private var engine: MobileEngine?
    private var generation = UUID()
    private let stateLock = NSLock()
    private var running = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let attempt = UUID(); self.generation = attempt
            do {
                guard let configuration = self.protocolConfiguration as? NETunnelProviderProtocol,
                      let idString = configuration.providerConfiguration?[SharedConstants.profileIDKey] as? String,
                      let id = UUID(uuidString: idString),
                      let raw = try KeychainSecretStore().read(profileID: id, kind: .xrayProfile) else {
                    throw self.safeError("Missing Xray profile in Keychain.")
                }
                let mode = configuration.providerConfiguration?["mode"] as? String ?? "direct"
                guard mode == "direct" || mode == "vkturn" else { throw self.safeError("Unknown engine mode.") }
                var error: NSError?
                let prepared: String
                let endpoint: String
                if mode == "direct" {
                    prepared = MobilePrepareProfile(raw, &error)
                    if error != nil { throw self.safeError("Unable to prepare the proxy endpoint.") }
                    endpoint = try JSONDecoder().decode(XrayProfile.self, from: Data(prepared.utf8)).address
                } else {
                    prepared = raw
                    endpoint = "127.0.0.1"
                }
                self.protector.start()
                self.setTunnelNetworkSettings(self.settings(endpoint: endpoint)) { [weak self] error in
                    guard let self else { return }
                    self.ioQueue.async {
                        guard self.generation == attempt else {
                            completionHandler(self.safeError("Tunnel start cancelled.")); return
                        }
                        guard error == nil else {
                            self.protector.stop(); completionHandler(self.safeError("Unable to set VPN routes.")); return
                        }
                        var coreError: NSError?
                        self.engine = mode == "vkturn"
                            ? MobileStartVK(prepared, self, self.protector, &coreError)
                            : MobileStart(prepared, self, self.protector, &coreError)
                        guard coreError == nil, self.engine != nil else {
                            self.engine?.stop(); self.engine = nil; self.protector.stop()
                            completionHandler(self.safeError("Unable to start Xray.")); return
                        }
                        self.stateLock.lock(); self.running = true; self.stateLock.unlock()
                        self.readPackets(attempt: attempt)
                        completionHandler(nil)
                    }
                }
            } catch {
                self.protector.stop()
                completionHandler(self.safeError("Unable to start the Xray profile."))
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ioQueue.async {
            self.generation = UUID()
            self.stateLock.lock(); self.running = false; self.stateLock.unlock()
            self.engine?.stop(); self.engine = nil
            self.protector.stop()
            completionHandler()
        }
    }

    private func readPackets(attempt: UUID) {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.ioQueue.async {
                guard self.generation == attempt, let engine = self.engine else { return }
                for packet in packets {
                    do { try engine.input(packet) }
                    catch { /* Malformed packets are dropped, never logged with data. */ }
                }
                self.readPackets(attempt: attempt)
            }
        }
    }

    func writePacket(_ packet: Data?) -> Bool {
        stateLock.lock(); let active = running; stateLock.unlock()
        guard active, let packet, let first = packet.first else { return false }
        let family: Int32
        switch first >> 4 { case 4: family = AF_INET; case 6: family = AF_INET6; default: return false }
        return packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)])
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        ioQueue.async {
            let status = self.engine?.status() ?? "stopped"
            let data = try? JSONSerialization.data(withJSONObject: ["engine": status])
            completionHandler?(data)
        }
    }

    private func settings(endpoint: String) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: endpoint)
        let ipv4 = NEIPv4Settings(addresses: ["10.77.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [.default()]
        let ipv6 = NEIPv6Settings(addresses: ["fd00:77::2"], networkPrefixLengths: [128])
        ipv6.includedRoutes = [.default()]
        // Do not add an endpoint /32 or /128 exclusion: that would bypass the
        // VPN for unrelated app traffic to a shared server IP. Only core sockets
        // receive the physical-interface protection callback.
        settings.ipv4Settings = ipv4; settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: ["1.1.1.1", "2606:4700:4700::1111"])
        dns.matchDomains = [""]; settings.dnsSettings = dns; settings.mtu = 1280
        return settings
    }

    private func safeError(_ message: String) -> NSError {
        NSError(domain: "BlinkXray", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
