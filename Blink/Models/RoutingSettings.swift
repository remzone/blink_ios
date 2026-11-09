import Foundation
import BlinkCore

struct LocalRoutingSettings: Codable {
    var mode = "inherit"
    var include = ""
    var exclude = ""
    static let key = "blink.routing.local.v1"
    static func load() -> Self { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self() }
    func resolved(server: RoutingPolicy?) throws -> RoutingPolicy {
        let source = try server.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        let local = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        var error: NSError?
        let value = MobileMergeRoutingPolicy(source, local, &error)
        guard error == nil else { throw RoutingSettingsError.invalid }
        return try JSONDecoder().decode(RoutingPolicy.self, from: Data(value.utf8))
    }
    func save() throws { _ = try resolved(server: Self.cachedPolicy()); UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.key) }
    static func cachedPolicy() -> RoutingPolicy? {
        let id = UUID(uuidString: "57f8b06a-c211-4b4f-8525-14cb2e7a882e")!
        guard let raw = try? KeychainSecretStore().read(profileID: id, kind: .subscriptionURL),
              let state = try? JSONDecoder().decode(SavedVokopSubscription.self, from: Data(raw.utf8)) else { return nil }
        return state.document?.routing
    }
}
enum RoutingSettingsError: LocalizedError {
    case invalid
    var errorDescription: String? { "Проверьте правила: домены или IP/CIDR, без адресов страниц и регулярных выражений. Для выборочного режима нужен хотя бы один адрес VPN." }
}
