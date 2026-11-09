import Foundation
import Darwin
import os

struct DiagnosticEvent: Codable, Identifiable, Sendable {
    let id: String
    let occurredAt: Int64
    let elapsedMs: Int64
    let source: String
    let event: String
    let fields: [String: Int64]
}
struct DiagnosticSession: Codable, Identifiable, Sendable {
    let id: String
    let createdAt: Int64
    let appVersion: String
    let build: String
}
struct DiagnosticCredential: Codable, Sendable {
    var endpoint: String
    var kind: String
    var enrollmentToken: String
    var uploadToken: String?
    var expiresAt: Int64?
    static let defaultID = UUID(uuidString: "25c45443-99fb-46aa-94a0-5593db5a5731")!
    static func destination(_ value: String) -> DiagnosticCredential? {
        guard value.utf8.count <= 4096, let c = URLComponents(string: value), c.scheme == "https", let host = c.host, !host.isEmpty, (1...65535).contains(c.port ?? 443), c.user == nil, c.password == nil else { return nil }
        for (marker, kind) in [("/api/vokop/v1/diagnostics/enroll/", "grant"), ("/api/vokop/v1/subscriptions/", "vokop"), ("/sub/", "standard")] {
            guard let range = c.path.range(of: marker, options: .backwards) else { continue }
            let token = String(c.path[range.upperBound...])
            guard (16...128).contains(token.count), token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
            var endpoint = c; endpoint.path = String(c.path[..<range.lowerBound]) + "/api/vokop/v1/diagnostics/sessions"; endpoint.query = nil; endpoint.fragment = nil
            guard let url = endpoint.url else { return nil }
            return .init(endpoint: url.absoluteString, kind: kind, enrollmentToken: token)
        }
        return nil
    }
    func save(id: UUID) throws {
        try KeychainSecretStore().save(String(decoding: JSONEncoder().encode(self), as: UTF8.self), profileID: id, kind: .diagnostics)
    }
    static func read(id: UUID) -> DiagnosticCredential? {
        guard let value = try? KeychainSecretStore().read(profileID: id, kind: .diagnostics) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(value.utf8))
    }
}

enum DiagnosticStore {
    static var sharedContainerAvailable: Bool { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroup) != nil }
    static var root: URL { SharedConstants.storageDirectory().appendingPathComponent("Diagnostics", isDirectory: true) }
    static func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func sessions() -> [DiagnosticSession] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: url.appendingPathComponent("session.json")) else { return nil }
            return try? JSONDecoder().decode(DiagnosticSession.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }
    static func pending(_ id: String, limit: Int = 64) -> [(URL, DiagnosticEvent)] {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory(id), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".event.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls.prefix(limit).compactMap { url in
            guard let data = try? Data(contentsOf: url), data.count <= 8192,
                  let event = try? JSONDecoder().decode(DiagnosticEvent.self, from: data) else { return nil }
            return (url, event)
        }
    }
    static func pendingCount() -> Int {
        sessions().reduce(0) { total, session in
            total + (((try? FileManager.default.contentsOfDirectory(at: directory(session.id), includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasSuffix(".event.json") }.count)
        }
    }
    static func allEvents(limit: Int = 300) -> [DiagnosticEvent] {
        sessions().suffix(5).flatMap { session -> [DiagnosticEvent] in
            let urls = ((try? FileManager.default.contentsOfDirectory(at: directory(session.id), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(".event.json") || $0.lastPathComponent.hasSuffix(".sent.json") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            return urls.prefix(limit).compactMap { url in
                guard let data = try? Data(contentsOf: url), data.count <= 8192 else { return nil }
                return try? JSONDecoder().decode(DiagnosticEvent.self, from: data)
            }
        }.sorted { $0.occurredAt > $1.occurredAt }.prefix(limit).map { $0 }
    }
    static func prune() {
        let sessions = sessions(); let cutoff = Int64(Date().timeIntervalSince1970) - 7 * 86400
        for (index, session) in sessions.enumerated() where session.createdAt < cutoff || index < sessions.count - 10 {
            try? FileManager.default.removeItem(at: directory(session.id))
            if let id = UUID(uuidString: session.id) { try? KeychainSecretStore().save("", profileID: id, kind: .diagnostics) }
        }
    }
    static func memory() -> [String: Int64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS else { return [:] }
        return ["residentBytes": Int64(info.resident_size), "footprintBytes": Int64(info.phys_footprint)]
    }
    static func errorFields(_ error: Error) -> [String: Int64] {
        if let keychain = error as? KeychainError, case let .unexpectedStatus(status) = keychain { return ["errorDomain": 9, "errorCode": Int64(status)] }
        let error = error as NSError
        let domains = ["NSURLErrorDomain", "NEVPNConnectionErrorDomain", "BlinkVPN", "NSPOSIXErrorDomain", "kCFErrorDomainCFNetwork", "Blink.VK", "NEVPNErrorDomain", "NSCocoaErrorDomain"]
        return ["errorDomain": Int64((domains.firstIndex(of: error.domain) ?? -1) + 1), "errorCode": Int64(error.code)]
    }
}

/// One atomic file per event: app and extension never overwrite one another's journal.
/// Only fixed event identifiers and numeric fields are accepted by the server.
final class DiagnosticRecorder: @unchecked Sendable {
    let session: DiagnosticSession
    let source: String
    private let queue = DispatchQueue(label: "com.blink.diagnostics.disk", qos: .utility)
    private let logger = Logger(subsystem: "com.blink.tunnel", category: "diagnostics")
    private var written = 0
    private var enabled = true
    func invalidateAndDrain() { queue.sync { enabled = false } }
    init(sessionID: String = UUID().uuidString, source: String = "app") {
        self.source = source
        let directory = DiagnosticStore.directory(sessionID)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")), let saved = try? JSONDecoder().decode(DiagnosticSession.self, from: data) { session = saved }
        else {
            session = .init(id: sessionID, createdAt: Int64(Date().timeIntervalSince1970), appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1", build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            if let data = try? JSONEncoder().encode(session) { try? data.write(to: directory.appendingPathComponent("session.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        }
    }
    func record(_ name: String, fields: [String: Int64] = [:], source override: String? = nil, critical: Bool = false, occurredAt: Int64? = nil) {
        let now = Date().timeIntervalSince1970
        let timeMs = occurredAt ?? Int64(now * 1000)
        let event = DiagnosticEvent(id: UUID().uuidString, occurredAt: timeMs, elapsedMs: max(0, timeMs - session.createdAt * 1000), source: override ?? source, event: name, fields: fields)
        let work: @Sendable () -> Void = { [self] in
            guard enabled else { return }
            let directory = DiagnosticStore.directory(session.id)
            guard let data = try? JSONEncoder().encode(event), data.count <= 8192 else { return }
            let url = directory.appendingPathComponent(String(format: "%016lld", event.occurredAt) + "-" + event.id + ".event.json")
            do { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } catch { logger.error("Diagnostic journal write failed") }
            logger.info("\(name, privacy: .public)")
            written += 1
            if written % 100 == 0 {
                let oldest = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasSuffix(".event.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                for url in oldest.prefix(max(0, oldest.count - 500)) { try? FileManager.default.removeItem(at: url) }
                let archive = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasSuffix(".sent.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                for url in archive.prefix(max(0, archive.count - 200)) { try? FileManager.default.removeItem(at: url) }
            }
        }
        if critical { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
    func marker(_ active: Bool) {
        let directory = DiagnosticStore.directory(session.id)
        let marker = directory.appendingPathComponent("tunnel-active")
        if active { try? Data().write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        else { try? FileManager.default.removeItem(at: marker) }
    }
}
