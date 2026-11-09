import Foundation

/// Preview-only wire model. Never convert this into a legacy WireGuard profile.
struct VokopSubscription: Codable {
    let schema: String
    let revision: Int64
    let issued_at: Int64
    let expires_at: Int64
    let profiles: [Profile]
    var routing: RoutingPolicy? = nil

    struct Profile: Codable, Identifiable {
        let id: String
        let name: String
        let backend: String?
        let wireguard: String?
        var backendTitle: String { backend == "wireguard" ? "WireGuard · \((turn.protocolName ?? "dtls").uppercased())" : "VLESS · KCP" }
        let vless: VLESS
        let turn: TURN
    }
    struct VLESS: Codable { let uuid: String }
    struct TURN: Codable {
        let protocolName: String?
        let wrap_key: String?
        let options: ServerOptions?
        enum CodingKeys: String, CodingKey { case protocolName = "protocol", wrap_key, options, peer_host, peer_port, vk_call_url, streams }
        let peer_host: String
        let peer_port: Int
        let vk_call_url: String
        let streams: Int
    }

    struct ServerOptions: Codable {
        let transport: String?; let preset: String?; let dns: String?; let relay: String?
        let mtu: Int?; let pace: Int?; let window: Int?; let interval: Int?; let congestion: Bool?
        func resolved() -> VKConnectionOptions {
            var o = VKConnectionOptions()
            o.transport = transport ?? "auto"; o.preset = preset ?? "compatibility"; o.bootstrapDNS = dns ?? "1.1.1.1"; o.turnServer = relay ?? ""
            o.mtu = mtu ?? 1200; o.paceKiB = pace ?? 0; o.window = window ?? 64; o.intervalMs = interval ?? 20; o.congestion = congestion ?? true; o.connections = 0
            return o
        }
    }

    func validate(now: Date = Date(), minimumRevision: Int64 = 0) throws {
        let timestamp = Int64(now.timeIntervalSince1970)
        guard expires_at > timestamp else { throw SubscriptionError.expired }
        guard issued_at <= timestamp + 300 else { throw SubscriptionError.futureDocument }
        guard revision >= minimumRevision else { throw SubscriptionError.outdatedRevision }
        guard ["vokop.subscription.v1", "vokop.subscription.v2", "vokop.subscription.v3"].contains(schema), revision > 0,
              revision <= 9_007_199_254_740_991,
              issued_at >= 0, expires_at > issued_at,
              expires_at <= 253_402_300_799,
              (1...16).contains(profiles.count),
              Set(profiles.map(\.id)).count == profiles.count else {
            throw SubscriptionError.invalidDocument
        }
        if schema == "vokop.subscription.v3", routing?.mode != "selected" { throw SubscriptionError.invalidDocument }
        if let routing { guard routing.schema == "blink.routing.v1", ["all", "selected"].contains(routing.mode), routing.revision > 0, routing.domains.count + routing.ips.count <= 20_000 else { throw SubscriptionError.invalidDocument } }
        for profile in profiles {
            let backend = profile.backend ?? "vless", wire = profile.turn.protocolName ?? "kcp"
            guard ["vless", "wireguard"].contains(backend), (backend != "wireguard" || schema == "vokop.subscription.v2" || schema == "vokop.subscription.v3"),
                  (backend == "vless" ? wire == "kcp" && profile.wireguard == nil : ["dtls", "srtp", "wrap"].contains(wire) && !(profile.wireguard ?? "").isEmpty && (profile.wireguard?.utf8.count ?? 0) <= 16384),
                  (wire == "wrap" ? Self.matches(profile.turn.wrap_key ?? "", "^[A-Fa-f0-9]{64}$") : (profile.turn.wrap_key ?? "").isEmpty),
                  profile.turn.options?.resolved().isValid ?? true else { throw SubscriptionError.invalidDocument }

            guard Self.matches(profile.id, "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"),
                  profile.name.unicodeScalars.count <= 100,
                  !profile.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  Self.matches(profile.vless.uuid, "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"),
                  Self.validPeerHost(profile.turn.peer_host),
                  (1...65535).contains(profile.turn.peer_port),
                  (1...16).contains(profile.turn.streams) else {
                throw SubscriptionError.invalidDocument
            }
            guard profile.turn.vk_call_url.utf8.count <= 2048,
                  Self.matches(profile.turn.vk_call_url, "^https://(www\\.)?vk\\.(com|ru)/call/join/[A-Za-z0-9_=-]+$") else {
                throw SubscriptionError.invalidCallURL
            }
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        // Anchoring with a full range also rejects a final newline ($ permits one).
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }

    private static func validPeerHost(_ host: String) -> Bool {
        guard host.utf8.count <= 253, host.contains("."),
              !host.lowercased().hasSuffix(".localhost") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let octets = labels.compactMap { UInt8($0) }
            guard octets.count == 4 else { return false }
            // Conservative: also exclude reserved class-E and CGNAT for this public endpoint.
            return octets[0] != 0 && octets[0] != 10 && octets[0] != 127 && octets[0] < 224
                && !(octets[0] == 169 && octets[1] == 254)
                && !(octets[0] == 172 && (16...31).contains(octets[1]))
                && !(octets[0] == 192 && octets[1] == 168)
                && !(octets[0] == 100 && (64...127).contains(octets[1]))
        }
        return labels.allSatisfy { matches(String($0), "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$") }
    }
}

enum SubscriptionError: LocalizedError {
    case invalidURL, invalidDocument, responseTooLarge, accessDenied, requestFailed
    case expired, futureDocument, outdatedRevision, invalidCallURL, reissued
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use the full HTTPS subscription link supplied by your administrator."
        case .invalidDocument: return "Формат подписки не поддерживается или параметры серверов некорректны. Обратитесь к администратору."
        case .reissued: return "Ключ подписки перевыпущен. Получите новую ссылку в боте провайдера и импортируйте её заново."
        case .expired: return "Срок подписки истёк. Проверьте дату и время устройства, затем обновите подписку."
        case .futureDocument: return "Дата выдачи подписки находится в будущем. Проверьте автоматическую настройку даты и времени устройства."
        case .outdatedRevision: return "Сервер вернул более старую версию подписки, чем уже сохранена. Обратитесь к администратору."
        case .invalidCallURL: return "В подписке некорректная ссылка звонка VK. Поддерживаются HTTPS-ссылки vk.com и vk.ru вида /call/join/… ."
        case .responseTooLarge: return "Subscription exceeds the size limit."
        case .accessDenied: return "Subscription access denied. Check your subscription with the administrator."
        case .requestFailed: return "Could not load the subscription securely. Check the link and network."
        }
    }
}

/// Stored with the credential-bearing URL in Keychain, never UserDefaults.
struct SavedVokopSubscription: Codable {
    let url: String
    let highestRevision: Int64
    let document: VokopSubscription?
}

struct SubscriptionAccount: Decodable {
    let schema: String
    let active: Bool
    let suspended: Bool
    let paid_until: Int64
    let remaining_seconds: Int64
    let checked_at: Int64
    let payment_url: String?
    var urgent: Bool { urgent(at: Date()) }
    func urgent(at now: Date) -> Bool { !active || paid_until - Int64(now.timeIntervalSince1970) <= 3 * 86400 }
    var balance: String {
        let seconds = max(0, paid_until - Int64(Date().timeIntervalSince1970))
        if seconds == 0 { return "Оплаченный срок закончился" }
        if seconds < 86400 { return "Осталось менее суток" }
        return "Осталось \(seconds / 86400) дн."
    }
}
