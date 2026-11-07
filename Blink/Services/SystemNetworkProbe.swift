import Foundation
import Darwin

/// Uses the iOS resolver, certificate store and IPv4/IPv6 selection.
/// With an active VPN these requests follow the system's VPN routes.
enum SystemNetworkProbe {
    static func check(kind: String, direct: Bool) async throws -> DiagnosticResult {
        let endpoints: [String]
        switch kind {
        case "ip": endpoints = ["https://www.cloudflare.com/cdn-cgi/trace", "https://api.ipify.org"]
        case "google": endpoints = ["https://www.google.com/generate_204"]
        case "youtube": endpoints = ["https://www.youtube.com/generate_204"]
        default: throw NetworkRequestError.connection
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: RejectProbeRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let started = Date()
        var lastError: Error = NetworkRequestError.connection
        for endpoint in endpoints {
            try Task.checkCancellation()
            do {
                let (bytes, response) = try await session.bytes(from: URL(string: endpoint)!)
                guard let http = response as? HTTPURLResponse else { throw NetworkRequestError.connection }
                guard http.statusCode == 200 || (kind != "ip" && http.statusCode == 204) else {
                    throw NetworkRequestError.httpStatus(http.statusCode)
                }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 8192 else { throw NetworkRequestError.connection }
                    data.append(byte)
                }
                let body = String(decoding: data, as: UTF8.self)
                let ip: String?
                if kind == "ip" {
                    let candidate = endpoint.contains("cloudflare.com")
                        ? body.components(separatedBy: .newlines).first(where: { $0.hasPrefix("ip=") }).map { String($0.dropFirst(3)) }
                        : body
                    guard let candidate, let valid = validatedIP(candidate) else { throw NetworkRequestError.connection }
                    ip = valid
                } else { ip = nil }
                return DiagnosticResult(kind: kind, direct: direct, ip: ip,
                                        dnsMs: nil, tcpMs: nil, tlsMs: nil, responseMs: nil,
                                        totalMs: Int(Date().timeIntervalSince(started) * 1000),
                                        checkedAt: Int64(Date().timeIntervalSince1970))
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch let error as NetworkRequestError { lastError = error }
            catch { lastError = NetworkRequestError.sanitized(error) }
        }
        throw lastError
    }

    static func validatedIP(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 45 else { return nil }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1
                || value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return nil }
        return value
    }
}

private final class RejectProbeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
