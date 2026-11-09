import Foundation

/// Some providers replace a revoked feed with a single loopback notification URI.
/// Recognize the explicit marker, never treat a display name as an instruction.
enum SubscriptionFeedNotice {
    static func validate(_ source: String) throws {
        guard source.utf8.count <= SecureSubscriptionHTTP.maximumBytes else { throw SubscriptionError.responseTooLarge }
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "\u{feff}" { text.removeFirst() }
        if !text.contains("://") {
            var encoded = text.filter { !$0.isWhitespace }
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard encoded.count % 4 != 1 else { return }
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else { return }
            text = decoded
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.count == 1 else { return }
        let resource = String(lines[0].prefix { $0 != "#" })
        guard let uri = URLComponents(string: resource),
              uri.scheme == "vless", uri.port == 1,
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(uri.host?.lowercased() ?? ""),
              uri.queryItems?.contains(where: { $0.name == "x-durev-reissue" && $0.value == "true" }) == true else { return }
        throw SubscriptionError.reissued
    }
}
