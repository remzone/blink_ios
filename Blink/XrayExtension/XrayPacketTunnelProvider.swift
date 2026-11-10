import Foundation
import NetworkExtension
import BlinkCore
import Darwin

/// One native Go runtime in this extension; legacy WireGuardKit/Mobile are not linked.
final class XrayPacketTunnelProvider: NEPacketTunnelProvider, MobilePacketWriterProtocol {
    private let ioQueue = DispatchQueue(label: "com.blink.unified.packets")
    private let protector = XraySocketProtector()
    private let stateLock = NSLock()
    private var engine: MobileEngine?
    private var generation = UUID()
    private var running = false
    private var selectiveRouting = false
    private var networkProfile: ImportedNetworkProfile?
    private var unreadySince: Date?
    private var diagnostics: DiagnosticRecorder?
    private var startedAt = Date()
    private var heartbeat = 0
    private var startupTicks = 0
    private var lastState = ""
    private var inputPackets: Int64 = 0
    private var outputPackets: Int64 = 0
    private var inputErrors: Int64 = 0
    private var outputErrors: Int64 = 0
    private var queueDelayMs: Int64 = 0
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var pendingStart: ((Error?) -> Void)?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let attempt = UUID(); self.generation = attempt; self.unreadySince = nil; self.pendingStart = completionHandler
            let publicConfig = self.protocolConfiguration as? NETunnelProviderProtocol
            let suppliedID = publicConfig?.providerConfiguration?["diagnosticsSessionID"] as? String
            MobileSetDiagnosticCollection(DiagnosticStore.collectionEnabled)
            self.diagnostics = DiagnosticRecorder(sessionID: suppliedID.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString, source: "extension")
            _ = MobileSetDiagnosticSession(self.diagnostics!.session.id)
            self.startedAt = Date(); self.heartbeat = 0; self.startupTicks = 0
            self.diagnostics?.record("extension.start", fields: DiagnosticStore.memory().merging(["sharedStorage": DiagnosticStore.sharedContainerAvailable ? 1 : 0]) { _, new in new }, critical: true)
            self.diagnostics?.marker(true)
            self.protector.diagnostics = self.diagnostics
            _ = MobileConfigureRuntime(32 * 1024 * 1024, 75)
            self.diagnostics?.record("extension.profile", fields: ["memoryLimitBytes": 32 * 1024 * 1024, "gcPercent": 75])
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: self.ioQueue)
            pressure.setEventHandler { [weak self] in
                self?.diagnostics?.record("extension.memory_warning", fields: DiagnosticStore.memory().merging(["reason": Int64(self?.memoryPressure?.data.rawValue ?? 0)]) { _, new in new }, critical: true)
            }
            self.memoryPressure = pressure; pressure.resume()
            var startupStage: Int64 = 1
            do {
                try NativeResources.prepare()
                startupStage = 2
                guard let config = self.protocolConfiguration as? NETunnelProviderProtocol,
                      let idString = config.providerConfiguration?[SharedConstants.profileIDKey] as? String,
                      let id = UUID(uuidString: idString),
                      let raw = try KeychainSecretStore().read(profileID: id, kind: .xrayProfile) else { throw self.safeError("Нет профиля в Keychain.") }
                let mode = config.providerConfiguration?["mode"] as? String ?? "direct"
                self.diagnostics?.record("extension.profile", fields: ["mode": mode == "vkturn" ? 1 : 0])
                startupStage = 3
                self.protector.start(); var error: NSError?
                if mode == "universal" {
                    struct Source: Decodable { let schema: String; let source: String; let routing: RoutingPolicy? }
                    let source = try JSONDecoder().decode(Source.self, from: Data(raw.utf8))
                    guard source.schema == "blink.profile.v1" else { throw self.safeError("Неверный формат VPN-профиля.") }
                    let prepared = MobileImportProfile(source.source, &error)
                    guard error == nil else { throw self.safeError("Протокол или параметры не поддерживаются.") }
                    self.networkProfile = try JSONDecoder().decode(ImportedNetworkProfile.self, from: Data(prepared.utf8))
                    self.selectiveRouting = source.routing?.mode == "selected"
                    if let routing = source.routing {
                        self.engine = MobileStartProfileRouted(prepared, String(decoding: try JSONEncoder().encode(routing), as: UTF8.self), self, self.protector, &error)
                    } else { self.engine = MobileStartProfile(prepared, self, self.protector, &error) }
                } else if mode == "direct" {
                    self.networkProfile = nil; self.selectiveRouting = false
                    let prepared = MobilePrepareProfile(raw, &error)
                    guard error == nil else { throw self.safeError("Не удалось подготовить адрес сервера.") }
                    self.engine = MobileStart(prepared, self, self.protector, &error)
                } else if mode == "vkturn" {
                    self.networkProfile = nil
                    guard var document = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                          let handoff = document["bootstrap"] as? String, !handoff.isEmpty else { throw self.safeError("Откройте Blink для авторизации TURN.") }
                    if document["backend"] as? String == "wireguard", let source = document["wireguard"] as? String {
                        let prepared = MobileImportProfile(source, &error)
                        guard error == nil else { throw self.safeError("Неверный WG-конфиг в подписке.") }
                        self.networkProfile = try JSONDecoder().decode(ImportedNetworkProfile.self, from: Data(prepared.utf8))
                    }
                    self.selectiveRouting = (document["routing"] as? [String: Any])?["mode"] as? String == "selected"
                    // Consume the short-lived handoff before creating a transport. Restarts reauthorize in the app.
                    document["bootstrap"] = ""
                    let consumed = try JSONSerialization.data(withJSONObject: document)
                    try KeychainSecretStore().save(String(decoding: consumed, as: UTF8.self), profileID: id, kind: .xrayProfile)
                    self.diagnostics?.record("extension.profile", fields: ["streams": Int64(document["streams"] as? Int ?? 0)])
                    self.engine = MobileStartVK(raw, self, self.protector, &error)
                } else { throw self.safeError("Неизвестный режим VPN.") }
                guard error == nil, self.engine != nil else { throw self.safeError("Не удалось запустить VPN. Проверьте профиль; для TURN повторите авторизацию в приложении.") }
                self.diagnostics?.record("extension.core_started", fields: DiagnosticStore.memory(), critical: true)
                self.waitForReady(attempt: attempt, deadline: Date().addingTimeInterval(40))
            } catch { self.diagnostics?.record("extension.failure", fields: DiagnosticStore.errorFields(error).merging(["stage": startupStage]) { _, new in new }, critical: true); self.failStart(self.safeError("VPN не запущен. Проверьте профиль, сеть и авторизацию TURN.")) }
        }
    }
    private func waitForReady(attempt: UUID, deadline: Date) {
        guard generation == attempt, let engine else { finishStart(safeError("Запуск отменён.")); return }
        drainNativeEvents()
        startupTicks += 1
        if startupTicks % 5 == 1 {
            var fields = DiagnosticStore.memory()
            if let runtime = try? JSONDecoder().decode([String: Int64].self, from: Data(MobileRuntimeStatsJSON().utf8)) { fields.merge(runtime) { _, new in new } }
            fields["uptimeMs"] = Int64(Date().timeIntervalSince(startedAt) * 1000)
            fields["stage"] = 0
            diagnostics?.record("extension.heartbeat", fields: fields)
        }
        let state = engine.status()
        if state == "ready" || state == "running" {
            do {
                let settings = try settings()
                diagnostics?.record("extension.routes_begin", fields: DiagnosticStore.memory(), critical: true)
                setTunnelNetworkSettings(settings) { [weak self] error in
                    guard let self else { return }
                    self.ioQueue.async {
                        guard self.generation == attempt else { self.finishStart(self.safeError("Запуск отменён.")); return }
                        guard error == nil else { self.failStart(self.safeError("Не удалось применить маршруты VPN.")); return }
                        self.stateLock.lock(); self.running = true; self.stateLock.unlock()
                        self.diagnostics?.record("extension.routes_ready", fields: DiagnosticStore.memory(), critical: true)
                        self.readPackets(attempt: attempt); self.finishStart(nil); self.monitor(attempt: attempt)
                    }
                }
            } catch { failStart(safeError("Неверные адреса или маршруты профиля.")) }
            return
        }
        guard state != "captcha_required", state != "stopped", Date() < deadline else { failStart(safeError("Транспорт не готов. Для TURN повторите авторизацию в Blink.")); return }
        ioQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.waitForReady(attempt: attempt, deadline: deadline) }
    }
    private func finishStart(_ error: Error?) { let callback = pendingStart; pendingStart = nil; callback?(error) }
    private func failStart(_ error: Error) { drainNativeEvents(); diagnostics?.record("extension.failure", fields: DiagnosticStore.errorFields(error), critical: true); diagnostics?.marker(false); memoryPressure?.cancel(); memoryPressure = nil; engine?.stop(); engine = nil; protector.stop(); finishStart(error) }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { completionHandler(); return }
            self.diagnostics?.record("extension.stop", fields: ["reason": Int64(reason.rawValue), "uptimeMs": Int64(Date().timeIntervalSince(self.startedAt) * 1000)], critical: true)
            self.diagnostics?.marker(false); self.memoryPressure?.cancel(); self.memoryPressure = nil
            self.generation = UUID(); self.stateLock.lock(); self.running = false; self.stateLock.unlock()
            self.engine?.stop(); self.engine = nil; self.protector.stop(); self.networkProfile = nil
            self.finishStart(self.safeError("Запуск отменён.")); completionHandler()
        }
    }
    private func monitor(attempt: UUID) {
        guard generation == attempt, let engine else { return }
        let state = engine.status()
        heartbeat += 1
        if state != lastState {
            lastState = state
            let states = ["stopped", "connecting", "captcha_required", "ready", "running"]
            diagnostics?.record("extension.state", fields: ["state": Int64(states.firstIndex(of: state) ?? -1)], critical: true)
        }
        if DiagnosticStore.collectionEnabled && (heartbeat <= 20 || heartbeat % 10 == 0) {
            var fields = DiagnosticStore.memory()
            if let runtime = try? JSONDecoder().decode([String: Int64].self, from: Data(MobileRuntimeStatsJSON().utf8)) { fields.merge(runtime) { _, new in new } }
            if let traffic = try? JSONDecoder().decode([String: Int64].self, from: Data(engine.statsJSON().utf8)) { fields["txBytes"] = traffic["tx"] ?? 0; fields["rxBytes"] = traffic["rx"] ?? 0 }
            stateLock.lock(); fields["outputPackets"] = outputPackets; fields["outputErrors"] = outputErrors; stateLock.unlock()
            fields["inputPackets"] = inputPackets; fields["inputErrors"] = inputErrors
            fields["uptimeMs"] = Int64(Date().timeIntervalSince(startedAt) * 1000); fields["queueDelayMs"] = queueDelayMs
            diagnostics?.record("extension.heartbeat", fields: fields)
        }
        drainNativeEvents()
        if state == "stopped" || state == "captcha_required" {
            diagnostics?.record("extension.failure", fields: ["stage": 6], critical: true)
            diagnostics?.marker(false); memoryPressure?.cancel(); memoryPressure = nil
            generation = UUID(); engine.stop(); self.engine = nil
            stateLock.lock(); running = false; stateLock.unlock()
            protector.stop()
            cancelTunnelWithError(safeError("Сессия завершена или TURN требует новую авторизацию. Откройте Blink и подключитесь заново.")); return
        }
        if state == "connecting" {
            if unreadySince == nil { unreadySince = Date() }
            if let since = unreadySince, Date().timeIntervalSince(since) > 45 {
                diagnostics?.record("extension.failure", fields: ["stage": 5], critical: true)
                diagnostics?.marker(false); memoryPressure?.cancel(); memoryPressure = nil
                generation = UUID(); engine.stop(); self.engine = nil
                stateLock.lock(); running = false; stateLock.unlock(); protector.stop()
                cancelTunnelWithError(safeError("Транспорт не восстановился за 45 секунд.")); return
            }
        } else { unreadySince = nil }
        let scheduled = Date()
        ioQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.queueDelayMs = max(0, Int64((Date().timeIntervalSince(scheduled) - 1) * 1000))
            self?.monitor(attempt: attempt)
        }
    }
    private func drainNativeEvents() {
        MobileSetDiagnosticCollection(DiagnosticStore.collectionEnabled)
        struct NativeEvent: Decodable { let event: String; let fields: [String: Int64]?; let sessionId: String?; let occurredAt: Int64? }
        if let rows = try? JSONDecoder().decode([NativeEvent].self, from: Data(MobileDrainDiagnosticEventsJSON().utf8)) {
            for row in rows where row.sessionId == nil || row.sessionId == diagnostics?.session.id {
                diagnostics?.record(row.event, fields: row.fields ?? [:], source: "native", occurredAt: row.occurredAt)
            }
        }
    }
    private func readPackets(attempt: UUID) {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.ioQueue.async {
                guard self.generation == attempt, let engine = self.engine else { return }
                for packet in packets { self.inputPackets += 1; do { try engine.input(packet) } catch { self.inputErrors += 1 } }
                self.readPackets(attempt: attempt)
            }
        }
    }
    func writePacket(_ packet: Data?) -> Bool {
        stateLock.lock(); let active = running; if active { outputPackets += 1 }; stateLock.unlock()
        guard active, let packet, let first = packet.first else { return false }
        let family: Int32; switch first >> 4 { case 4: family = AF_INET; case 6: family = AF_INET6; default: return false }
        let accepted = packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)])
        if !accepted { stateLock.lock(); outputErrors += 1; stateLock.unlock() }
        return accepted
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        ioQueue.async { completionHandler?(try? JSONSerialization.data(withJSONObject: ["engine": self.engine?.status() ?? "stopped"])) }
    }
    private func settings() throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let explicitWG = !selectiveRouting && (networkProfile.map { $0.kind == "wireguard" || $0.kind == "amneziawg" } ?? false)
        let addresses = explicitWG ? networkProfile!.addresses : (selectiveRouting ? ["10.77.0.2/32", "fd77::2/128"] : ["10.77.0.2/32"])
        let routes = explicitWG ? networkProfile!.routes : (selectiveRouting ? ["0.0.0.0/0", "::/0"] : ["0.0.0.0/0"])
        var v4: [String] = []; var masks: [String] = []; var v6: [String] = []; var prefixes: [NSNumber] = []
        for value in addresses {
            let p = try cidr(value)
            if p.0.contains(":") { v6.append(p.0); prefixes.append(NSNumber(value: p.1)) } else { v4.append(p.0); masks.append(mask(p.1)) }
        }
        if !v4.isEmpty { let ip = NEIPv4Settings(addresses: v4, subnetMasks: masks); ip.includedRoutes = try routes.filter { !$0.contains(":") }.map { let p = try cidr($0); return NEIPv4Route(destinationAddress: p.0, subnetMask: mask(p.1)) }; settings.ipv4Settings = ip }
        if !v6.isEmpty { let ip = NEIPv6Settings(addresses: v6, networkPrefixLengths: prefixes); ip.includedRoutes = try routes.filter { $0.contains(":") }.map { let p = try cidr($0); return NEIPv6Route(destinationAddress: p.0, networkPrefixLength: NSNumber(value: p.1)) }; settings.ipv6Settings = ip }
        // Xray/VK do not advertise the unverified IPv6 path. includeAllNetworks is set in manager preferences.
        // No server-IP exclusion: only core sockets get physical-interface protection.
        let dns = NEDNSSettings(servers: explicitWG ? networkProfile!.dns : ["1.1.1.1"])
        dns.matchDomains = [""]; settings.dnsSettings = dns; settings.mtu = NSNumber(value: explicitWG ? networkProfile!.mtu : 1280)
        return settings
    }
    private func cidr(_ value: String) throws -> (String, Int) { let p = value.split(separator: "/"); guard p.count == 2, let n = Int(p[1]), (0...(p[0].contains(":") ? 128 : 32)).contains(n) else { throw safeError("Неверный CIDR.") }; return (String(p[0]), n) }
    private func mask(_ prefix: Int) -> String { let n: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix); return [24, 16, 8, 0].map { String((n >> $0) & 255) }.joined(separator: ".") }
    private func safeError(_ message: String) -> NSError { NSError(domain: "BlinkVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
