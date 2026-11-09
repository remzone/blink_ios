import Foundation
import Darwin

/// Non-secret local preferences. Keys, call links and relay credentials stay in Keychain.
struct VKConnectionOptions: Codable, Equatable {
    static let storageKey = "vokop.connectionOptions.v1"
    var serverDefaults: Bool? = nil
    var followsServer: Bool { serverDefaults != false }
    func resolved(for turn: VokopSubscription.TURN) -> Self {
        guard followsServer else { return self }; var value = turn.options?.resolved() ?? Self(); value.connections = 0; return value
    }
    var transport = "auto"
    var preset = "compatibility"
    var connections = 1
    var mtu = 1200
    var paceKiB = 0
    var window = 64
    var intervalMs = 20
    var congestion = true
    var bootstrapDNS = "1.1.1.1"
    var turnServer = ""

    struct Tuning: Encodable {
        let preset: String; let mtu: Int; let paceKiB: Int
        let window: Int; let intervalMs: Int; let congestion: Bool
    }
    var tuning: Tuning {
        Tuning(preset: preset, mtu: mtu, paceKiB: paceKiB,
               window: preset == "custom" ? window : 0,
               intervalMs: preset == "custom" ? intervalMs : 0,
               congestion: preset == "custom" && congestion)
    }
    var presetTitle: String {
        switch preset {
        case "balanced": return "Сбалансированный"
        case "conservative": return "Бережный"
        case "custom": return "Вручную"
        default: return "Совместимость"
        }
    }
    var isValid: Bool {
        ["auto", "udp", "tcp"].contains(transport)
            && ["compatibility", "balanced", "conservative", "custom"].contains(preset)
            && (0...16).contains(connections) && (576...1200).contains(mtu)
            && (paceKiB == 0 || (16...4096).contains(paceKiB))
            && (16...256).contains(window) && (10...100).contains(intervalMs)
            && Self.isIP(bootstrapDNS) && Self.validRelay(turnServer)
    }
    static func isIP(_ value: String) -> Bool {
        // inet_pton is available in the iOS app without DNS/network side effects.
        var v4 = in_addr(); var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    static func validRelay(_ value: String) -> Bool {
        if value.isEmpty { return true }
        guard value.utf8.count <= 260, let url = URLComponents(string: "turn://" + value),
              let host = url.host, !host.isEmpty, let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil else { return false }
        return isIP(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) || host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-"
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
    static func load(defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: storageKey), let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid { return value }
        var value = Self()
        value.transport = defaults.string(forKey: "vokop.turnTransport.v2") ?? "auto"
        value.bootstrapDNS = defaults.string(forKey: "vokop.bootstrapDNS") ?? "1.1.1.1"
        return value.isValid ? value : Self()
    }
    func save(defaults: UserDefaults = .standard) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
