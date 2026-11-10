import Foundation
import Combine
import BlinkCore

@MainActor
final class DiagnosticCenter: ObservableObject {
    static let shared = DiagnosticCenter()
    @Published private(set) var sessionID: String
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSent = 0
    @Published private(set) var sending = false
    @Published private(set) var lastHTTPStatus = 0
    @Published private(set) var events: [DiagnosticEvent] = []
    private(set) var recorder: DiagnosticRecorder
    private var loop: Task<Void, Never>?
    private var recentRecorders: [String: DiagnosticRecorder] = [:]
    private var userStopped = false
    private var foreground = true
    private var foregroundGeneration = UUID()
    @Published private(set) var collectionEnabled = DiagnosticStore.collectionEnabled
    func setCollectionEnabled(_ enabled: Bool) { DiagnosticStore.collectionEnabled = enabled; collectionEnabled = enabled; MobileSetDiagnosticCollection(enabled) }
    init() {
        MobileSetDiagnosticCollection(DiagnosticStore.collectionEnabled)
        let recorder = DiagnosticRecorder(); self.recorder = recorder; sessionID = recorder.session.id
        recorder.record("app.launch", fields: DiagnosticStore.memory().merging(["sharedStorage": DiagnosticStore.sharedContainerAvailable ? 1 : 0]) { _, new in new }, critical: true)
    }
    func start() {
        guard loop == nil else { return }
        DiagnosticStore.prune()
        loop = Task { [weak self] in
            var initialSnapshot = true
            while !Task.isCancelled {
                guard let self else { return }
                if initialSnapshot || self.collectionEnabled {
                initialSnapshot = false
                let snapshot = await Task.detached(priority: .utility) { (DiagnosticStore.pendingCount(), DiagnosticStore.allEvents()) }.value
                self.pendingCount = snapshot.0; self.events = snapshot.1
                }
                let scheduled = Date(), revision = self.foregroundGeneration
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                let delay = Int64(max(0, (Date().timeIntervalSince(scheduled) - 5) * 1000))
                if self.foreground && self.foregroundGeneration == revision && delay > 1000 { self.record("app.main_thread_lag", fields: ["elapsedMs": delay]) }
            }
        }
    }
    func setForeground(_ active: Bool) { foreground = active; foregroundGeneration = UUID() }
    func begin(sourceURL: String?, mode: Int64, fields: [String: Int64] = [:]) {
        let previous = recorder
        recentRecorders[previous.session.id] = previous
        if recentRecorders.count > 3 { recentRecorders = [previous.session.id: previous] }
        recorder = DiagnosticRecorder(); sessionID = recorder.session.id; userStopped = false
        DiagnosticStore.prune()
        let manual = DiagnosticCredential.read(id: DiagnosticCredential.defaultID)
        let destination = (manual?.kind == "grant" ? manual : nil) ?? sourceURL.flatMap(DiagnosticCredential.destination) ?? manual
        if let destination, let id = UUID(uuidString: sessionID) {
            do { try destination.save(id: id) }
            catch { recorder.record("upload.state", fields: DiagnosticStore.errorFields(error), critical: true) }
            if let previousID = UUID(uuidString: previous.session.id), DiagnosticCredential.read(id: previousID) == nil { try? destination.save(id: previousID) }
        }
        recorder.record("connection.begin", fields: fields.merging(["mode": mode]) { _, new in new }, critical: true)
    }
    func configure(_ value: String) throws {
        guard let destination = DiagnosticCredential.destination(value), destination.kind == "grant" else { throw DiagnosticHTTPError.invalid }
        try destination.save(id: DiagnosticCredential.defaultID)
        for session in DiagnosticStore.sessions() {
            if let id = UUID(uuidString: session.id), DiagnosticCredential.read(id: id)?.uploadToken == nil { try destination.save(id: id) }
        }
    }
    func resume(sessionID: String) {
        guard UUID(uuidString: sessionID) != nil else { return }
        recorder = DiagnosticRecorder(sessionID: sessionID); self.sessionID = sessionID
        record("app.foreground")
    }
    func record(_ name: String, fields: [String: Int64] = [:], critical: Bool = false) { recorder.record(name, fields: fields, critical: critical) }
    func requestedStop() { userStopped = true; record("connection.cancel", critical: true) }
    func disconnected() {
        let current = recorder, expected: Int64 = userStopped ? 1 : 0
        record("connection.disconnected", critical: true)
        Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            if FileManager.default.fileExists(atPath: DiagnosticStore.directory(current.session.id).appendingPathComponent("tunnel-active").path) {
                // Missing normal-stop marker indicates interruption; it does not prove jetsam.
                current.record("extension.interrupted", fields: ["reason": expected], critical: true)
                current.marker(false)
            }
        }
    }
    func flushNow() async {
        guard !sending else { return }; sending = true
        defer { sending = false }
        let sent = await DiagnosticUploader.shared.flush()
        lastSent += sent
        lastHTTPStatus = await DiagnosticUploader.shared.lastHTTPStatus
        let snapshot = await Task.detached(priority: .utility) { (DiagnosticStore.pendingCount(), DiagnosticStore.allEvents()) }.value
        pendingCount = snapshot.0; events = snapshot.1
    }
    func resetLocal() {
        guard !sending else { return }
        recorder.invalidateAndDrain()
        for value in recentRecorders.values { value.invalidateAndDrain() }
        recentRecorders.removeAll()
        for session in DiagnosticStore.sessions() {
            try? FileManager.default.removeItem(at: DiagnosticStore.directory(session.id))
            if let id = UUID(uuidString: session.id) { try? KeychainSecretStore().save("", profileID: id, kind: .diagnostics) }
        }
        _ = MobileDrainDiagnosticEventsJSON()
        recorder = DiagnosticRecorder(); sessionID = recorder.session.id
        pendingCount = 0; events = []; lastSent = 0; lastHTTPStatus = 0
    }
    func drainNative() {
        struct NativeEvent: Decodable { let event: String; let fields: [String: Int64]?; let sessionId: String?; let occurredAt: Int64? }
        if let rows = try? JSONDecoder().decode([NativeEvent].self, from: Data(MobileDrainDiagnosticEventsJSON().utf8)) {
            for row in rows {
                let target = row.sessionId == nil || row.sessionId == recorder.session.id ? recorder : recentRecorders[row.sessionId ?? ""]
                target?.record(row.event, fields: row.fields ?? [:], source: "native", occurredAt: row.occurredAt)
            }
        }
    }
}
