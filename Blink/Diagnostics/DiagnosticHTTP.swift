import Foundation
import Network

struct DiagnosticHTTPResponse { let status: Int; let data: Data }
enum DiagnosticHTTPError: Error { case invalid, unavailable }

/// HTTPS only. Never redirects credentials. Physical retries explicitly require Wi-Fi/cellular.
enum DiagnosticHTTP {
    static func post(_ url: URL, token: String, body: Data) async throws -> DiagnosticHTTPResponse {
        guard url.scheme == "https", url.host != nil, (1...65535).contains(url.port ?? 443), url.user == nil, url.password == nil, !token.contains(where: { $0 == "\r" || $0 == "\n" }), body.count <= 65536 else { throw DiagnosticHTTPError.invalid }
        do {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 4
            let session = URLSession(configuration: config, delegate: DiagnosticNoRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw DiagnosticHTTPError.invalid }
            var data = Data(); for try await byte in bytes { guard data.count < 65536 else { throw DiagnosticHTTPError.invalid }; data.append(byte) }
            return .init(status: http.statusCode, data: data)
        } catch is CancellationError { throw CancellationError() }
        catch {
            for type: NWInterface.InterfaceType in [.wifi, .cellular, .wiredEthernet] {
                try Task.checkCancellation()
                do { return try await PhysicalDiagnosticRequest(url: url, token: token, body: body, interface: type).run() }
                catch { continue }
            }
            throw DiagnosticHTTPError.unavailable
        }
    }
}
private final class DiagnosticNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class PhysicalDiagnosticRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.blink.diagnostics.physical", qos: .utility)
    private let connection: NWConnection
    private let request: Data
    private var continuation: CheckedContinuation<DiagnosticHTTPResponse, Error>?
    private var received = Data()
    private var cancelled = false
    init(url: URL, token: String, body: Data, interface: NWInterface.InterfaceType) {
        let parameters = NWParameters.tls
        parameters.requiredInterfaceType = interface
        connection = NWConnection(host: NWEndpoint.Host(url.host!), port: NWEndpoint.Port(rawValue: UInt16(url.port ?? 443))!, using: parameters)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        components.path = ""; components.query = nil
        let authority = url.host! + (url.port.map { ":\($0)" } ?? "")
        let headers = "POST \(path) HTTP/1.1\r\nHost: \(authority)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
        request = Data(headers.utf8) + body
    }
    func run() async throws -> DiagnosticHTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !self.cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    connection.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.connection.send(content: self.request, completion: .contentProcessed { [weak self] error in
                                guard let self else { return }
                                if error != nil { self.finish(.failure(DiagnosticHTTPError.unavailable)) } else { self.receive() }
                            })
                        case .failed, .cancelled: self.finish(.failure(DiagnosticHTTPError.unavailable))
                        default: break
                        }
                    }
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 4) { [weak self] in self?.finish(.failure(DiagnosticHTTPError.unavailable)) }
                }
            }
        }, onCancel: { [self] in queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) } })
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, self.continuation != nil else { return }
            if let data { self.received.append(data) }
            guard self.received.count <= 65536 else { self.finish(.failure(DiagnosticHTTPError.invalid)); return }
            if complete { self.finish(DiagnosticHTTPParser.parse(self.received)); return }
            if error != nil { self.finish(.failure(DiagnosticHTTPError.unavailable)); return }
            self.receive()
        }
    }
    private func finish(_ result: Result<DiagnosticHTTPResponse, Error>) {
        guard let continuation else { return }; self.continuation = nil
        connection.stateUpdateHandler = nil; connection.cancel(); continuation.resume(with: result)
    }
}

enum DiagnosticHTTPParser {
    static func parse(_ data: Data) -> Result<DiagnosticHTTPResponse, Error> {
        guard data.count <= 65536, let split = data.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: data[..<split.lowerBound], encoding: .utf8),
              headers.hasPrefix("HTTP/1."),
              let status = headers.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return .failure(DiagnosticHTTPError.invalid) }
        var body = Data(data[split.upperBound...])
        if headers.lowercased().contains("transfer-encoding: chunked") {
            var decoded = Data()
            while let line = body.range(of: Data("\r\n".utf8)),
                  let text = String(data: body[..<line.lowerBound], encoding: .ascii),
                  let size = Int(text.split(separator: ";").first ?? "", radix: 16), size >= 0 {
                body = Data(body[line.upperBound...])
                if size == 0 { return .success(.init(status: status, data: decoded)) }
                guard size <= body.count - 2, Data(body.dropFirst(size).prefix(2)) == Data("\r\n".utf8) else { return .failure(DiagnosticHTTPError.invalid) }
                decoded.append(body.prefix(size)); body = Data(body.dropFirst(size + 2))
            }
            return .failure(DiagnosticHTTPError.invalid)
        }
        for line in headers.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            guard let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)), length == body.count else { return .failure(DiagnosticHTTPError.invalid) }
        }
        return .success(.init(status: status, data: body))
    }
}
