import Foundation

enum SharedProfileReader {
    static func profile(id: UUID) throws -> VPNProfile {
        let url = SharedConstants.storageDirectory().appendingPathComponent("profiles.json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profiles = try decoder.decode([VPNProfile].self, from: data)
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw TunnelError.profileNotFound
        }
        return profile
    }
}

enum TunnelError: LocalizedError {
    case invalidProviderConfiguration
    case profileNotFound
    case missingWireGuardPrivateKey
    case invalidWireGuardPrivateKey
    case invalidPeerPublicKey
    case invalidAddress(String)
    case invalidDNS(String)
    case invalidAllowedIP(String)
    case freeTurn(String)
    case freeTurnTimeout
    case wireGuard(String)

    var errorDescription: String? {
        switch self {
        case .invalidProviderConfiguration: "Invalid tunnel provider configuration"
        case .profileNotFound: "Selected profile was not found"
        case .missingWireGuardPrivateKey: "WireGuard private key is missing"
        case .invalidWireGuardPrivateKey: "WireGuard private key is invalid"
        case .invalidPeerPublicKey: "WireGuard peer public key is invalid"
        case let .invalidAddress(value): "Invalid WireGuard address: \(value)"
        case let .invalidDNS(value): "Invalid DNS server: \(value)"
        case let .invalidAllowedIP(value): "Invalid allowed IP: \(value)"
        case let .freeTurn(value): "Free TURN: \(value)"
        case .freeTurnTimeout: "Free TURN connection timed out"
        case let .wireGuard(value): "WireGuard: \(value)"
        }
    }
}
