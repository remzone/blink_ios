import Foundation
import Combine
import NetworkExtension
import BlinkCore

@MainActor
final class XrayVPNController: ObservableObject {
    @Published private(set) var status = "Отключён"
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    let authorization = VKPreflightAuthorizer()
    @Published private(set) var profileName = "Выберите VPN-профиль"
    @Published private(set) var authorizationPhase: VKAuthorizationPhase = .starting
    @Published private(set) var route: ConnectionRoute?
    @Published private(set) var connectionState: NEVPNStatus = .disconnected
    var isConnecting: Bool { busy || connectionState == .connecting || connectionState == .reasserting }
    var isDisconnecting: Bool { connectionState == .disconnecting }
    var hasActiveConnection: Bool { isConnected || isConnecting || isDisconnecting }
    var isConnected: Bool { manager?.connection.status == .connected }
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
        catch { errorMessage = "Не удалось прочитать VLESS-профиль." }
    }

    func connect(profile: XrayProfile, secrets: SecretStore) async {
        do { await connect(json: try profile.json(), mode: "direct", server: profile.address, secrets: secrets) }
        catch { errorMessage = "Не удалось сохранить VLESS-профиль." }
    }

    func connectUniversal(source: String, name: String, secrets: SecretStore, diagnosticURL: String? = nil) async {
        guard !busy else { return }
        do {
            try NativeResources.prepare()
            var nativeError: NSError?
            let metadata = MobileImportProfile(source, &nativeError)
            guard nativeError == nil else { throw UniversalProfileError.invalid }
            let profile = try JSONDecoder().decode(ImportedNetworkProfile.self, from: Data(metadata.utf8))
            let wg = profile.kind == "wireguard" || profile.kind == "amneziawg"
            let has4 = profile.addresses.contains { !$0.contains(":") }, has6 = profile.addresses.contains { $0.contains(":") }
            let full = !wg || ((!has4 || profile.routes.contains("0.0.0.0/0")) && (!has6 || profile.routes.contains("::/0")))
            let routing = try LocalRoutingSettings.load().resolved(server: LocalRoutingSettings.cachedPolicy())
            let routingObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(routing))
            let payload: [String: Any] = ["schema": "blink.profile.v1", "source": source, "routing": routingObject]
            let data = try JSONSerialization.data(withJSONObject: payload)
            profileName = name
            await connect(json: String(decoding: data, as: UTF8.self), mode: "universal", server: "Blink VPN", captureAll: routing.mode == "selected" ? false : full, secrets: secrets, diagnosticURL: diagnosticURL)
        } catch { errorMessage = "Не удалось сохранить VPN-профиль." }
    }
    func connect(profile: VokopSubscription.Profile, expiresAt: Int64, options: VKConnectionOptions = .load(), secrets: SecretStore, diagnosticURL: String? = nil) async {
        guard PanelStatusCenter.shared.status?.maintenance != true else { errorMessage = "На сервере технические работы. Попробуйте позже."; return }
        guard !busy else { return }
        guard manager == nil || [.invalid, .disconnected].contains(manager!.connection.status) else { errorMessage = "Сначала отключите текущий VPN."; return }
        let options = VKConnectionOptions().resolved(for: profile.turn)
        struct VKProfile: Encodable {
            let backend: String; let `protocol`: String; let wrapKey: String; let wireguard: String
            let uuid: String; let peerHost: String; let peerPort: Int; let vkCallURL: String
            let streams: Int; let expiresAt: Int64; let dnsServer: String
            let turnServer: String; let tuning: VKConnectionOptions.Tuning
            let manualCaptcha = true; let turnTransport: String; var bootstrap = ""; var routing: RoutingPolicy?
        }
        guard expiresAt > Int64(Date().timeIntervalSince1970), options.isValid else { errorMessage = "Подписка истекла или неверный транспорт."; return }
        let streams = options.connections == 0 ? profile.turn.streams : options.connections
        let id = UUID(); operation = id; busy = true; errorMessage = nil
        route = .vk; profileName = profile.name; authorizationPhase = .starting
        DiagnosticCenter.shared.begin(sourceURL: diagnosticURL, mode: 1, fields: ["streams": Int64(streams)])
        status = "Авторизация VK · используется обычная сеть"
        do {
            let existing = try await NETunnelProviderManager.loadAllFromPreferences().first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == SharedConstants.xrayTunnelBundleIdentifier }
            guard operation == id else { return }
            guard existing == nil || [.invalid, .disconnected].contains(existing!.connection.status) else { busy = false; errorMessage = "Сначала отключите текущий VPN."; return }
            manager = existing
            var value = VKProfile(backend: profile.backend ?? "vless", protocol: profile.turn.protocolName ?? "kcp", wrapKey: profile.turn.wrap_key ?? "", wireguard: profile.wireguard ?? "", uuid: profile.vless.uuid, peerHost: profile.turn.peer_host, peerPort: profile.turn.peer_port, vkCallURL: profile.turn.vk_call_url, streams: streams, expiresAt: expiresAt, dnsServer: options.bootstrapDNS, turnServer: options.turnServer, tuning: options.tuning, turnTransport: options.transport)
            value.routing = try LocalRoutingSettings.load().resolved(server: LocalRoutingSettings.cachedPolicy())
            var captureAll = true
            if let source = profile.wireguard {
                var err: NSError?
                let raw = MobileImportProfile(source, &err)
                guard err == nil else { throw UniversalProfileError.invalid }
                let network = try JSONDecoder().decode(ImportedNetworkProfile.self, from: Data(raw.utf8))
                captureAll = (!network.addresses.contains { !$0.contains(":") } || network.routes.contains("0.0.0.0/0")) && (!network.addresses.contains { $0.contains(":") } || network.routes.contains("::/0"))
            }
            if value.routing?.mode == "selected" { captureAll = false }
            let data = try JSONEncoder().encode(value)
            value.bootstrap = try await authorization.authorize(String(decoding: data, as: UTF8.self)) { [weak self] phase in
                guard let self, self.operation == id, self.authorizationPhase != phase else { return }
                DiagnosticCenter.shared.record("captcha.phase", fields: DiagnosticStore.memory().merging(["phase": phase.diagnosticCode]) { _, new in new })
                self.authorizationPhase = phase
                self.status = phase.message
            }
            guard operation == id else { return }; busy = false
            profileName = profile.name
            let prepared = try JSONEncoder().encode(value)
            await connect(json: String(decoding: prepared, as: UTF8.self), mode: "vkturn", server: profile.turn.peer_host, captureAll: captureAll, secrets: secrets)
        } catch {
            guard operation == id else { return }
            DiagnosticCenter.shared.record("connection.failed", fields: DiagnosticStore.errorFields(error), critical: true)
            busy = false; status = "Не подключён"
            if error is CancellationError { errorMessage = "Авторизация VK отменена. Повторите подключение." }
            else if let error = error as? VKAuthorizationError { errorMessage = error.localizedDescription }
            else if let error = error as? NetworkRequestError { errorMessage = error.localizedDescription }
            else { errorMessage = "Не удалось подготовить авторизацию VK. Повторите подключение." }
        }
    }

    private func connect(json: String, mode: String, server: String, captureAll: Bool = true, secrets: SecretStore, diagnosticURL: String? = nil) async {
        guard !hasActiveConnection else { errorMessage = "Сначала отключите текущий VPN."; return }
        route = ConnectionRoute.fromProviderMode(mode)
        if mode != "vkturn" { DiagnosticCenter.shared.begin(sourceURL: diagnosticURL, mode: 0) }
        let attempt = UUID(); operation = attempt
        busy = true; errorMessage = nil
        defer { if operation == attempt { busy = false } }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard operation == attempt else { return }
            let manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == SharedConstants.xrayTunnelBundleIdentifier } ?? NETunnelProviderManager()
            // Do not overwrite credentials underneath a running extension.
            guard [.invalid, .disconnected].contains(manager.connection.status) else {
                errorMessage = "Сначала отключите текущий VPN."; return
            }
            try secrets.save(json, profileID: credentialID, kind: .xrayProfile)
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = SharedConstants.xrayTunnelBundleIdentifier
            configuration.serverAddress = server
            configuration.includeAllNetworks = captureAll
            configuration.excludeLocalNetworks = captureAll
            configuration.providerConfiguration = [SharedConstants.profileIDKey: credentialID.uuidString, "mode": mode, "diagnosticsSessionID": DiagnosticCenter.shared.sessionID]
            manager.protocolConfiguration = configuration
            manager.localizedDescription = mode == "vkturn" ? "Blink — VK TURN" : "Blink — VPN"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            guard operation == attempt else { return }
            try await manager.loadFromPreferences()
            guard operation == attempt else { return }
            self.manager = manager
            try manager.connection.startVPNTunnel()
            consume(manager.connection.status)
        } catch { if operation == attempt { DiagnosticCenter.shared.record("connection.failed", fields: DiagnosticStore.errorFields(error), critical: true); errorMessage = "Не удалось запустить VPN. Проверьте разрешение и профиль." } }
    }

    func disconnect() {
        DiagnosticCenter.shared.requestedStop()
        operation = UUID()
        authorization.cancel(); busy = false
        manager?.connection.stopVPNTunnel()
        if let manager { consume(manager.connection.status) }
        else { consume(.disconnected) }
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
                        case "ready": self.status = "VPN подключён · VK готов"
                        case "connecting": self.status = "VPN подключён · восстановление VK"
                        case "captcha_required": self.status = "VK требует новую проверку. Отключите VPN и подключитесь из приложения."
                        case "stopped": self.status = "Соединение остановлено. Переподключитесь или обновите подписку."
                        default: self.status = "VPN настроен · доступ в интернет ещё не проверен"
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
            if let configuration = restored?.protocolConfiguration as? NETunnelProviderProtocol {
                if let sessionID = configuration.providerConfiguration?["diagnosticsSessionID"] as? String { DiagnosticCenter.shared.resume(sessionID: sessionID) }
                route = ConnectionRoute.fromProviderMode(configuration.providerConfiguration?["mode"] as? String)
                profileName = route == .vk ? "Подключение через VK" : "Сохранённый VPN-профиль"
            }
            if let manager {
                consume(manager.connection.status)
                if [.disconnected, .invalid].contains(manager.connection.status), FileManager.default.fileExists(atPath: DiagnosticStore.directory(DiagnosticCenter.shared.sessionID).appendingPathComponent("tunnel-active").path) {
                    DiagnosticCenter.shared.disconnected()
                    let recorder = DiagnosticCenter.shared.recorder
                    manager.connection.fetchLastDisconnectError { error in
                        if let error { recorder.record("provider.error", fields: DiagnosticStore.errorFields(error), critical: true) }
                    }
                }
            }
        } catch { errorMessage = "Не удалось восстановить настройки VPN." }
    }
    private func consume(_ state: NEVPNStatus) {
        let previous = connectionState
        if previous != state {
            DiagnosticCenter.shared.record("connection.state", fields: ["state": Int64(state.rawValue)], critical: true)
            if state == .disconnected || state == .invalid {
                DiagnosticCenter.shared.disconnected()
                let recorder = DiagnosticCenter.shared.recorder
                manager?.connection.fetchLastDisconnectError { error in
                    guard let error else { return }
                    let fields = DiagnosticStore.errorFields(error)
                    recorder.record("provider.error", fields: fields, critical: true)
                }
            }
        }
        connectionState = state
        switch state {
        case .connected: status = "VPN подключён · проверьте интернет"
        case .connecting, .reasserting: status = "Подключение…"
        case .disconnecting: status = "Отключение…"
        default: status = "Отключён"
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
