import Foundation

/// No cookies, disk cache, redirects, or credential-bearing error descriptions.
final class VokopSubscriptionClient {
    static let maximumBytes = 128 * 1024

    static func validatedURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 4096,
              let components = URLComponents(string: value), components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == components.path,
              let marker = components.path.range(of: "/api/vokop/v1/subscriptions/", options: .backwards),
              marker.upperBound < components.path.endIndex,
              let url = components.url else { throw SubscriptionError.invalidURL }
        let token = String(components.path[marker.upperBound...])
        guard (32...128).contains(token.count),
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw SubscriptionError.invalidURL
        }
        return url
    }

    func fetch(_ value: String, minimumRevision: Int64 = 0) async throws -> VokopSubscription {
        let url = try Self.validatedURL(value)
        do {
            let data = try await SecureSubscriptionHTTP().fetch(url.absoluteString, accept: "application/json")
            let document = try JSONDecoder().decode(VokopSubscription.self, from: data)
            try document.validate(minimumRevision: minimumRevision)
            return document
        } catch is DecodingError {
            throw SubscriptionError.invalidDocument
        }
    }
}
