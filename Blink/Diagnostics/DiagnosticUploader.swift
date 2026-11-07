import Foundation
import Darwin

actor DiagnosticUploader {
    static let shared = DiagnosticUploader()
    private var working = false
    private var statuses: [String: Int] = [:]
    private var nextAttempts: [String: Date] = [:]
    private var retryDelays: [String: TimeInterval] = [:]
    private(set) var lastHTTPStatus = 0
    private func status(_ code: Int, session: String) {
        lastHTTPStatus = code
        if statuses[session] != code {
            statuses[session] = code
            DiagnosticRecorder(sessionID: session).record("upload.state", fields: ["httpStatus": Int64(code)])
        }
        if code == 200 { nextAttempts[session] = nil; retryDelays[session] = nil }
        else { let delay = min(60, (retryDelays[session] ?? 2.5) * 2); retryDelays[session] = delay; nextAttempts[session] = Date().addingTimeInterval(delay) }
    }
    func flush() async -> Int {
        guard !working else { return 0 }
        let descriptor = open(DiagnosticStore.root.appendingPathComponent("upload.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return 0 }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return 0 }
        working = true
        defer { working = false; flock(descriptor, LOCK_UN); close(descriptor) }
        var sent = 0
        var attempts = 0
        for session in DiagnosticStore.sessions().suffix(10).reversed() {
            if let next = nextAttempts[session.id], next > Date() { continue }
            guard attempts < 3 else { break }
            guard !Task.isCancelled, let id = UUID(uuidString: session.id) else { break }
            let pending = DiagnosticStore.pending(session.id)
            guard !pending.isEmpty else { continue }
            guard var credential = DiagnosticCredential.read(id: id) ?? DiagnosticCredential.read(id: DiagnosticCredential.defaultID),
                  let endpoint = URL(string: credential.endpoint), endpoint.scheme == "https" else { continue }
            attempts += 1
            do {
                if credential.uploadToken == nil {
                    let body = try JSONSerialization.data(withJSONObject: ["sessionId": session.id, "kind": credential.kind, "platform": "ios", "appVersion": session.appVersion, "build": session.build])
                    let result = try await DiagnosticHTTP.post(endpoint, token: credential.enrollmentToken, body: body)
                    guard result.status == 200 else { status(result.status, session: session.id); continue }
                    struct Enrollment: Decodable { let sessionId: String; let uploadToken: String; let expiresAt: Int64 }
                    let response = try JSONDecoder().decode(Enrollment.self, from: result.data)
                    guard response.sessionId == session.id else { continue }
                    credential.uploadToken = response.uploadToken; credential.expiresAt = response.expiresAt
                    try credential.save(id: id)
                }
                guard let token = credential.uploadToken else { continue }
                struct Batch: Encodable { let events: [DiagnosticEvent] }
                var selected = pending
                var body = try JSONEncoder().encode(Batch(events: selected.map(\.1)))
                while body.count > 60000 && selected.count > 1 { selected.removeLast(); body = try JSONEncoder().encode(Batch(events: selected.map(\.1))) }
                let result = try await DiagnosticHTTP.post(endpoint.appendingPathComponent(session.id).appendingPathComponent("events"), token: token, body: body)
                guard result.status == 200 else { status(result.status, session: session.id); continue }
                struct Ack: Decodable { let accepted: [String] }
                let ack = try JSONDecoder().decode(Ack.self, from: result.data)
                let ids = Set(ack.accepted)
                for (url, event) in selected where ids.contains(event.id) {
                    let archive = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".event.json", with: ".sent.json"))
                    try? FileManager.default.moveItem(at: url, to: archive); sent += 1
                }
                status(200, session: session.id)
            } catch { status(-1, session: session.id); continue } // Keep files and credentials for later delivery; never log token-bearing errors.
            if sent >= 64 { break }
        }
        return sent
    }
}
