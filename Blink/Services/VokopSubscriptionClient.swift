import Foundation
import BlinkCore

/// No cookies, disk cache, cross-origin redirects, or credential-bearing error descriptions.
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

    static func fetchControl(_ url: String) async throws -> Data {
        let protector = XraySocketProtector(); protector.start()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { protector.stop() }
                var error: NSError?
                let raw = MobileFetchPanelControl(url, protector, &error)
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: Data(raw.utf8)) }
            }
        }
    }
    static func statusURL(subscription: String) throws -> String {
        let value = try validatedURL(subscription).absoluteString
        guard let marker = value.range(of: "/api/vokop/v1/subscriptions/", options: .backwards) else { throw SubscriptionError.invalidURL }
        return String(value[..<marker.lowerBound]) + "/api/vokop/v1/status"
    }
    func fetch(_ value: String, minimumRevision: Int64 = 0) async throws -> VokopSubscription {
        let url = try Self.validatedURL(value)
        do {
            let data = try await Self.fetchControl(url.absoluteString)
            let document = try JSONDecoder().decode(VokopSubscription.self, from: data)
            try document.validate(minimumRevision: minimumRevision)
            return document
        } catch is DecodingError {
            throw SubscriptionError.invalidDocument
        }
    }
}
