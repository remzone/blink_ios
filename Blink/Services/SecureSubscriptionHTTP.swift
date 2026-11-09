import Foundation

/// Shared bounded HTTPS transport. Token URLs never enter errors, logs or caches. Redirects stay on the original HTTPS origin.
final class SecureSubscriptionHTTP: NSObject, URLSessionTaskDelegate {
    private let redirectLock = NSLock()
    private var redirectCounts: [ObjectIdentifier: Int] = [:]

    static let maximumBytes = 1024 * 1024
    static func validatedURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 4096,
              let c = URLComponents(string: value), c.scheme == "https",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.fragment == nil,
              let url = c.url else { throw SubscriptionError.invalidURL }
        return url
    }

    // Some subscription APIs negotiate JSON renderers before returning a plain/base64 feed.
    // Let the endpoint select its representation; ImportProfiles validates the actual body.
    func fetch(_ value: String, accept: String = "*/*") async throws -> Data {
        let url = try Self.validatedURL(value)
        let diagnostics = await MainActor.run { DiagnosticCenter.shared.recorder }
        diagnostics.record("subscription.fetch")
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
        request.setValue("Blink/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw SubscriptionError.requestFailed }
            diagnostics.record("subscription.result", fields: ["httpStatus": Int64(http.statusCode)])
            if [401, 403, 404].contains(http.statusCode) { throw SubscriptionError.accessDenied }
            guard http.statusCode == 200 else { throw NetworkRequestError.httpStatus(http.statusCode) }
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
        } catch let error as NetworkRequestError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            diagnostics.record("subscription.result", fields: DiagnosticStore.errorFields(error))
            throw NetworkRequestError.sanitized(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        redirectLock.lock()
        redirectCounts.removeValue(forKey: ObjectIdentifier(task))
        redirectLock.unlock()
    }

    static func allowsRedirect(from original: URL, to target: URL, count: Int) -> Bool {
        guard (1...5).contains(count),
              let checked = try? validatedURL(target.absoluteString),
              checked.host?.lowercased() == original.host?.lowercased(),
              (checked.port ?? 443) == (original.port ?? 443) else { return false }
        return true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirectLock.lock()
        let count = (redirectCounts[ObjectIdentifier(task)] ?? 0) + 1
        redirectCounts[ObjectIdentifier(task)] = count
        redirectLock.unlock()
        guard let original = task.originalRequest?.url,
              let target = request.url,
              task.countOfBytesReceived <= Int64(Self.maximumBytes),
              Self.allowsRedirect(from: original, to: target, count: count) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
