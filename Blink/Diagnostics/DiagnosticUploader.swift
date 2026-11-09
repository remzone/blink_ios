import Foundation
import Darwin

/// Invoked only by the foreground user's Send button. One click sends a frozen snapshot.
actor DiagnosticUploader {
    static let shared = DiagnosticUploader()
    private var working = false
    private(set) var lastHTTPStatus = 0
    private func status(_ code: Int, session: String) {
        lastHTTPStatus = code
        DiagnosticRecorder(sessionID: session).record("upload.state", fields: ["httpStatus": Int64(code)])
    }
    func flush() async -> Int {
        guard !working else { return 0 }
        let descriptor = open(DiagnosticStore.root.appendingPathComponent("upload.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return 0 }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return 0 }
        working = true; lastHTTPStatus = 0
        defer { working = false; flock(descriptor, LOCK_UN); close(descriptor) }
        let snapshot = DiagnosticStore.sessions().suffix(10).reversed().map { ($0, DiagnosticStore.pending($0.id, limit: 500)) }
        let deadline = Date().addingTimeInterval(90)
        var sent = 0
        for (session, pending) in snapshot {
            guard !Task.isCancelled, Date() < deadline, let id = UUID(uuidString: session.id) else { break }
            guard !pending.isEmpty else { continue }
            guard var credential = DiagnosticCredential.read(id: id) ?? DiagnosticCredential.read(id: DiagnosticCredential.defaultID),
                  let endpoint = URL(string: credential.endpoint), endpoint.scheme == "https" else { continue }
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
                var offset = 0
                while offset < pending.count && !Task.isCancelled && Date() < deadline {
                    struct Batch: Encodable { let events: [DiagnosticEvent] }
                    var selected = Array(pending[offset..<min(offset + 64, pending.count)])
                    var body = try JSONEncoder().encode(Batch(events: selected.map(\.1)))
                    while body.count > 60000 && selected.count > 1 { selected.removeLast(); body = try JSONEncoder().encode(Batch(events: selected.map(\.1))) }
                    let result = try await DiagnosticHTTP.post(endpoint.appendingPathComponent(session.id).appendingPathComponent("events"), token: token, body: body)
                    guard result.status == 200 else { status(result.status, session: session.id); break }
                    struct Ack: Decodable { let accepted: [String] }
                    let ids = Set(try JSONDecoder().decode(Ack.self, from: result.data).accepted)
                    for (url, event) in selected where ids.contains(event.id) {
                        let archive = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".event.json", with: ".sent.json"))
                        try? FileManager.default.moveItem(at: url, to: archive); sent += 1
                    }
                    guard selected.allSatisfy({ ids.contains($0.1.id) }) else { status(-1, session: session.id); break }
                    offset += selected.count
                    lastHTTPStatus = 200
                }
            } catch { status(-1, session: session.id) } // Keep records for the next explicit attempt.
        }
        return sent
    }
}
