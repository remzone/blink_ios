import Foundation

@MainActor enum ManagedSubscriptionStore {
    static let vaultID = UUID(uuidString: "81487391-25f0-41c7-a31c-1454e4c18400")!
    @discardableResult static func apply(_ document: VokopSubscription, url: String, store: SecretStore) throws -> [UniversalProfile] {
        let old = try store.read(profileID: vaultID, kind: .universalProfiles).flatMap { try JSONDecoder().decode([UniversalProfile].self, from: Data($0.utf8)) } ?? []
        guard let sources = document.vpn_profiles else { return old }
        guard sources.count <= 128, sources.reduce(0, { $0 + $1.utf8.count }) <= 524288 else { throw SubscriptionError.invalidDocument }
        var added: [UniversalProfile] = []
        var rejected = 0
        for source in sources {
            let parsed: ([UniversalProfile], Int, String)
            do { parsed = try UniversalProfile.imported(source) } catch { rejected += 1; continue }
            let (profiles, skipped, _) = parsed; rejected += skipped
            for var profile in profiles {
                if let previous = old.first(where: { $0.managedByPanel != nil && $0.source == profile.source }) { profile.id = previous.id }
                profile.managedByPanel = url; profile.subscriptionURL = url
                profile.subscriptionMetadata = SubscriptionMetadata(title: document.metadata?.title ?? "Blink · VPN и TURN", announcement: document.metadata?.announcement, expiresAt: document.expires_at, updatedAt: Date())
                added.append(profile)
            }
        }
        UserDefaults.standard.set(rejected, forKey: "blink.managedVPNRejected")
        let next = old.filter { $0.managedByPanel == nil } + added
        guard next.count <= 1024 else { throw UniversalProfileError.invalid }
        let data = try JSONEncoder().encode(next); guard data.count <= 4194304 else { throw UniversalProfileError.invalid }
        try store.save(String(decoding: data, as: UTF8.self), profileID: vaultID, kind: .universalProfiles)
        return next
    }
    static func remove(store: SecretStore) throws {
        let old = try store.read(profileID: vaultID, kind: .universalProfiles).flatMap { try JSONDecoder().decode([UniversalProfile].self, from: Data($0.utf8)) } ?? []
        try store.save(String(decoding: try JSONEncoder().encode(old.filter { $0.managedByPanel == nil }), as: UTF8.self), profileID: vaultID, kind: .universalProfiles)
    }
    static func botURL(_ raw: String?) -> URL? {
        guard let raw, let u = URLComponents(string: raw), u.scheme == "https", u.host == "t.me", u.user == nil, u.password == nil, u.port == nil, u.query == nil, u.fragment == nil,
              u.path.range(of: "^/[A-Za-z][A-Za-z0-9_]{4,31}$", options: .regularExpression) != nil else { return nil }
        return u.url
    }
}
