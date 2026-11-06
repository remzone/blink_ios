import Foundation
import BlinkCore

/// Source includes secrets; the entire array lives only in shared Keychain.
struct UniversalProfile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var kind: String
    var source: String
    var subscriptionURL: String?
    init(name: String, kind: String, source: String) { self.name = name; self.kind = kind; self.source = source }
    static func imported(_ text: String) throws -> ([UniversalProfile], Int, String) {
        try NativeResources.prepare()
        guard text.utf8.count <= 1048576 else { throw UniversalProfileError.invalid }
        var nativeError: NSError?
        let json = MobileImportProfiles(text, &nativeError)
        guard nativeError == nil else { throw UniversalProfileError.invalid }
        struct Response: Decodable { struct Node: Decodable { let name: String; let kind: String; let source: String }; struct Rejected: Decodable { let index: Int }; let profiles: [Node]; let rejected: [Rejected]; let notice: String? }
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        return (response.profiles.map { .init(name: $0.name, kind: $0.kind, source: $0.source) }, response.rejected.count, response.notice ?? "")
    }
}
enum UniversalProfileError: LocalizedError {
    case invalid
    var errorDescription: String? { "Не удалось импортировать профиль. Проверьте протокол, параметры и размер файла. Неизвестные параметры не применяются." }
}
struct ImportedNetworkProfile: Decodable {
    let schema: String; let kind: String; let name: String; let source: String
    let addresses: [String]; let dns: [String]; let routes: [String]; let mtu: Int
}
