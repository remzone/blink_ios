import Foundation

/// Preview-only wire model. Never convert this into a legacy WireGuard profile.
struct VokopSubscription: Decodable {
    let schema: String
    let revision: Int64
    let issued_at: Int64
    let expires_at: Int64
    let profiles: [Profile]

    struct Profile: Decodable, Identifiable {
        let id: String
        let name: String
        let vless: VLESS
        let turn: TURN
    }
    struct VLESS: Decodable { let uuid: String }
    struct TURN: Decodable {
        let peer_host: String
        let peer_port: Int
        let vk_call_url: String
        let streams: Int
    }

    func validate(now: Date = Date(), minimumRevision: Int64 = 0) throws {
        let timestamp = Int64(now.timeIntervalSince1970)
        guard schema == "vokop.subscription.v1", revision > 0,
              revision <= 9_007_199_254_740_991, revision >= minimumRevision,
              issued_at >= 0, issued_at <= timestamp + 300,
              expires_at > timestamp, expires_at > issued_at,
              expires_at - issued_at <= 2_678_400,
              (1...16).contains(profiles.count),
              Set(profiles.map(\.id)).count == profiles.count else {
            throw SubscriptionError.invalidDocument
        }
        for profile in profiles {
            guard Self.matches(profile.id, "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"),
                  profile.name.unicodeScalars.count <= 100,
                  !profile.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  Self.matches(profile.vless.uuid, "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"),
                  Self.validPeerHost(profile.turn.peer_host),
                  (1...65535).contains(profile.turn.peer_port),
                  (1...16).contains(profile.turn.streams),
                  profile.turn.vk_call_url.utf8.count <= 2048,
                  Self.matches(profile.turn.vk_call_url, "^https://(www\\.)?vk\\.com/call/join/[A-Za-z0-9_=-]+$") else {
                throw SubscriptionError.invalidDocument
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
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use the full HTTPS Vokop subscription link supplied by your administrator."
        case .invalidDocument: return "Subscription is invalid, expired, or older than the last loaded revision."
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
}
