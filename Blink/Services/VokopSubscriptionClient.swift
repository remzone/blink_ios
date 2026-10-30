import Foundation

/// No cookies, disk cache, redirects, or credential-bearing error descriptions.
final class VokopSubscriptionClient: NSObject, URLSessionTaskDelegate {
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw SubscriptionError.requestFailed }
            if [401, 403, 404].contains(http.statusCode) { throw SubscriptionError.accessDenied }
            guard http.statusCode == 200 else { throw SubscriptionError.requestFailed }
            guard response.expectedContentLength <= Int64(Self.maximumBytes) else { throw SubscriptionError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumBytes else { throw SubscriptionError.responseTooLarge }
                data.append(byte)
            }
            let document = try JSONDecoder().decode(VokopSubscription.self, from: data)
            try document.validate(minimumRevision: minimumRevision)
            return document
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubscriptionError {
            throw error
        } catch is DecodingError {
            throw SubscriptionError.invalidDocument
        } catch {
            // URLSession errors may contain the full bearer-token URL. Never expose them.
            throw SubscriptionError.requestFailed
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
