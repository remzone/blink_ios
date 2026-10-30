import Foundation

/// Shared bounded HTTPS transport. Token URLs never enter errors, logs or caches.
final class SecureSubscriptionHTTP: NSObject, URLSessionTaskDelegate {
    static let maximumBytes = 128 * 1024
    static func validatedURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 4096,
              let c = URLComponents(string: value), c.scheme == "https",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.fragment == nil,
              let url = c.url else { throw SubscriptionError.invalidURL }
        return url
    }

    func fetch(_ value: String, accept: String = "text/plain, application/octet-stream;q=0.9") async throws -> Data {
        let url = try Self.validatedURL(value)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
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
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubscriptionError {
            throw error
        } catch {
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
