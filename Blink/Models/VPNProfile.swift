import Foundation

struct VPNProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var server: String
    var port: Int
    var wireGuard: WireGuardConfiguration
    var freeTurn: FreeTurnConfiguration
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(), name: String = "My VPN", server: String = "",
        port: Int = 56_000, wireGuard: WireGuardConfiguration = .init(),
        freeTurn: FreeTurnConfiguration = .init(), notes: String = "",
        createdAt: Date = .now, updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.server = server
        self.port = port
        self.wireGuard = wireGuard
        self.freeTurn = freeTurn
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct WireGuardConfiguration: Codable, Equatable, Hashable {
    var address = "10.77.0.2/32"
    var dns = "1.1.1.1"
    var allowedIPs = ["0.0.0.0/0"]
    var publicKey = ""
    var persistentKeepAlive: UInt16 = 25
    var mtu: UInt16 = 1280
}

struct FreeTurnConfiguration: Codable, Equatable, Hashable {
    var vkLink = ""
    var obfProfile = "rtpopus"
    var clientID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var listenPort: UInt16 = 9_000
}

struct ProfileSecrets: Equatable {
    var wireGuardPrivateKey = ""
    var obfuscationKey = ""
}
