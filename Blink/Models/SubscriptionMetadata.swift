import Foundation

/// Display-only information. Stored with subscription profiles in Keychain.
struct SubscriptionMetadata: Codable, Equatable, Sendable {
    var title: String?
    var announcement: String?
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    var expiresAt: Int64?

    var used: Int64? {
        guard upload != nil || download != nil else { return nil }
        let (value, overflow) = (upload ?? 0).addingReportingOverflow(download ?? 0)
        return overflow ? nil : value
    }
    var trafficSummary: String? {
        guard let used else { return nil }
        let amount = ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)
        guard let total, total > 0 else { return "Использовано \(amount)" }
        return "\(amount) из \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary))"
    }
    var fractionUsed: Double? {
        guard let used, let total, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
    static func parse(headers: [String: String], body: Data) -> Self {
        var values: [String: String] = [:]
        for (key, value) in headers { values[key.lowercased()] = value }
        // Body directives are used by providers that cannot set custom HTTP headers.
        if body.count <= 1_048_576, var text = String(data: body, encoding: .utf8) {
            if !text.contains("://"), let decoded = decodeBase64(text), decoded.utf8.count <= 1_048_576 { text = decoded }
            for line in text.components(separatedBy: .newlines) {
                let line = line.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[line.index(after: line.startIndex)..<colon]).lowercased()
                if ["profile-title", "announce", "subscription-userinfo"].contains(key), values[key] == nil {
                    values[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        func label(_ key: String, limit: Int) -> String? {
            guard let raw = values[key], raw.utf8.count <= 4096 else { return nil }
            let value: String
            if raw.hasPrefix("base64:") {
                guard let decoded = decodeBase64(String(raw.dropFirst(7))) else { return nil }; value = decoded
            } else { value = raw }
            let clean = ProfilePresentation.clean(value, limit: limit)
            return clean.isEmpty ? nil : clean
        }
        var numbers: [String: Int64] = [:]
        if let userInfo = values["subscription-userinfo"], userInfo.utf8.count <= 4096 {
            for field in userInfo.split(separator: ";") {
                let parts = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, ["upload", "download", "total", "expire"].contains(parts[0]),
                      let value = Int64(parts[1]), value >= 0 else { continue }
                numbers[parts[0]] = value
            }
        }
        // Valid Date range for a provider expiry; 0 means no expiry supplied.
        let expiry = numbers["expire"].flatMap { (1...253_402_300_799).contains($0) ? $0 : nil }
        return Self(title: label("profile-title", limit: 120), announcement: label("announce", limit: 240),
                    upload: numbers["upload"], download: numbers["download"], total: numbers["total"], expiresAt: expiry)
    }
    private static func decodeBase64(_ value: String) -> String? {
        var encoded = value.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard encoded.count % 4 != 1 else { return nil }
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct ProfilePresentation {
    let title: String
    let emoji: String?
    let countryCode: String?
    var country: String? { countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) } }

    init(name: String) {
        let clean = Self.clean(name, limit: 120)
        let flag = clean.first { Self.flagCode($0) != nil }
        let symbol = flag ?? clean.first { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (character.unicodeScalars.contains { $0.value == 0xFE0F } && character.unicodeScalars.contains { $0.properties.isEmoji })
        }
        emoji = symbol.map(String.init)
        countryCode = flag.flatMap(Self.flagCode)
        // Only remove the leading icon. Other emoji in the provider's name stay intact.
        if let symbol, clean.first == symbol {
            let remainder = clean.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            title = remainder.isEmpty ? clean : remainder
        } else { title = clean }
    }
    static func clean(_ value: String, limit: Int) -> String {
        // Preserve ZWJ and emoji tags, so family/occupation/subdivision emoji survive.
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0.value == 0x200D || (0xE0020...0xE007F).contains($0.value)
        }
        return String(String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
    private static func flagCode(_ character: Character) -> String? {
        let scalars = Array(character.unicodeScalars)
        guard scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) else { return nil }
        let code = String(String.UnicodeScalarView(scalars.compactMap { UnicodeScalar($0.value - 0x1F1E6 + 65) }))
        return Locale.isoRegionCodes.contains(code) ? code : nil
    }
}
