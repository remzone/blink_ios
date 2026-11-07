import Foundation
import Combine
import UIKit
import BlinkCore
import VKCaptchaSDK

/// Runs in the foreground app before starting NE routes. No challenge/token is persisted.
@MainActor
final class VKPreflightAuthorizer: NSObject, ObservableObject, MobilePacketWriterProtocol {
    struct LegacyChallenge: Identifiable { let id: String; let image: URL }
    struct ModernChallenge: Identifiable { let id: String; let controller: UIViewController }
    @Published var legacy: LegacyChallenge?
    @Published var modern: ModernChallenge?
    private let protector = XraySocketProtector()
    private var engine: MobileEngine?
    private var starting = false
    private let nativeQueue = DispatchQueue(label: "com.blink.vk.preflight-core", qos: .userInitiated)
    private var sdk: VKCaptcha?
    private var attempt = UUID()
    private var answer: CheckedContinuation<String, Error>?
    private var pendingChallengeID: String?
    private var timer: Task<Void, Never>?
    nonisolated func writePacket(_ packet: Data?) -> Bool { true }

    func authorize(_ json: String, onProgress: (VKAuthorizationPhase) -> Void = { _ in }) async throws -> String {
        guard engine == nil, !starting else { throw VKAuthorizationError.alreadyRunning }
        let id = UUID(); attempt = id; protector.diagnostics = DiagnosticCenter.shared.recorder; protector.start()
        _ = MobileConfigureRuntime(96 * 1024 * 1024, 100)
        onProgress(.starting)
        starting = true
        let started: MobileEngine
        let protector = self.protector
        let diagnosticSessionID = DiagnosticCenter.shared.sessionID
        do {
            started = try await withCheckedThrowingContinuation { continuation in
                nativeQueue.async { [self] in
                    _ = MobileSetDiagnosticSession(diagnosticSessionID)
                    var error: NSError?
                    let value = MobileStartVK(json, self, protector, &error)
                    if error != nil || value == nil { value?.stop(); continuation.resume(throwing: VKAuthorizationError.startFailed) }
                    else { continuation.resume(returning: value!) }
                }
            }
        } catch {
            starting = false; protector.stop(); throw error
        }
        starting = false
        guard attempt == id, !Task.isCancelled else {
            nativeQueue.async { started.stop() }; throw CancellationError()
        }
        engine = started
        defer { if attempt == id { DiagnosticCenter.shared.drainNative(); cancel() } }
        let deadline = Date().addingTimeInterval(300)
        var progress = VKAuthorizationProgress()
        while Date() < deadline {
            try Task.checkCancellation()
            guard attempt == id, let engine else { throw CancellationError() }
            DiagnosticCenter.shared.drainNative()
            let status = engine.status()
            if status == "ready" {
                let handoff = await withCheckedContinuation { continuation in
                    nativeQueue.async { continuation.resume(returning: engine.exportVKBootstrap()) }
                }
                try Task.checkCancellation()
                guard attempt == id else { throw CancellationError() }
                if !handoff.isEmpty { onProgress(.ready); return handoff }
                // Readiness can change between Status and ExportVKBootstrap.
            } else if status == "captcha_required" {
                let data = Data(engine.captchaJSON().utf8)
                struct Challenge: Decodable { let id: String?; let url: String?; let image: String?; let expires_at: Int64? }
                guard let challenge = try? JSONDecoder().decode(Challenge.self, from: data) else {
                    throw VKAuthorizationError.invalidResponse
                }
                // An empty object is possible while the worker clears a consumed challenge.
                if let challengeID = challenge.id, progress.shouldPresent(challengeID) {
                    guard let expiresAt = challenge.expires_at, expiresAt > Int64(Date().timeIntervalSince1970) else {
                        throw VKAuthorizationError.expired
                    }
                    onProgress(.captcha)
                    let token: String; let kind: String
                    let seconds = max(1, expiresAt - Int64(Date().timeIntervalSince1970))
                    if let value = challenge.url, let url = trustedURL(value) {
                        kind = "token"; token = try await solve(id: challengeID, url: url, seconds: seconds)
                    } else if let value = challenge.image, let url = trustedURL(value) {
                        kind = "key"; token = try await legacyAnswer(id: challengeID, image: url, seconds: seconds)
                    } else { throw VKAuthorizationError.unsupportedChallenge }
                    try Task.checkCancellation()
                    guard attempt == id else { throw CancellationError() }
                    guard engine.submitCaptcha(challengeID, kind: kind, value: token) else { throw VKAuthorizationError.rejectedAnswer }
                    progress.submitted(challengeID)
                    onProgress(.verifying)
                }
            } else if status == "stopped" { throw VKAuthorizationError.stopped }
            else if progress.submittedChallengeID != nil { onProgress(.transport) }
            if progress.responseTimedOut() { throw VKAuthorizationError.transportTimedOut }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw VKAuthorizationError.expired
    }

    func cancel() {
        attempt = UUID()
        finish(.failure(CancellationError()))
        sdk = nil
        let previous = engine; engine = nil; protector.stop()
        nativeQueue.async { previous?.stop() }
    }
    func submitLegacy(_ code: String) {
        guard let id = legacy?.id else { return }
        finish(.success(code), challengeID: id)
    }
    func cancelLegacy() {
        guard let id = legacy?.id else { return }
        cancelChallenge(id)
    }
    func cancelChallenge(_ id: String) { finish(.failure(CancellationError()), challengeID: id) }

    private func legacyAnswer(id: String, image: URL, seconds: Int64) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                answer = continuation; pendingChallengeID = id
                legacy = .init(id: id, image: image); expire(after: seconds, challengeID: id)
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancelChallenge(id) } })
    }
    private func solve(id: String, url: URL, seconds: Int64) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                answer = continuation; pendingChallengeID = id
                let captcha = VKCaptcha(configuration: .init(url: url, theme: .system)); sdk = captcha
                let current = attempt
                // Embed in the current SwiftUI scene instead of creating a separate UIWindow.
                let controller = captcha.getCaptchaViewController { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.attempt == current, self.pendingChallengeID == id else { return }
                        switch result {
                        case .success(let token): self.finish(.success(token), challengeID: id)
                        case .failure(let error):
                            let failure: Error
                            if let sdkError = error as? VKCaptchaResultError, sdkError == .cancel { failure = CancellationError() }
                            else if let sdkError = error as? VKCaptchaResultError, sdkError == .connection { failure = NetworkRequestError.connection }
                            else { failure = VKAuthorizationError.rejectedAnswer }
                            self.finish(.failure(failure), challengeID: id)
                        }
                    }
                }
                modern = .init(id: id, controller: controller)
                expire(after: seconds, challengeID: id)
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancelChallenge(id) } })
    }
    private func expire(after seconds: Int64, challengeID: String) {
        timer?.cancel(); let id = attempt
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.attempt == id else { return }
            self.finish(.failure(VKAuthorizationError.expired), challengeID: challengeID)
        }
    }
    private func finish(_ result: Result<String, Error>, challengeID: String? = nil) {
        if let challengeID, pendingChallengeID != challengeID { return }
        timer?.cancel(); timer = nil
        let continuation = answer; answer = nil; pendingChallengeID = nil
        modern = nil; legacy = nil; sdk = nil
        continuation?.resume(with: result)
    }
    private func trustedURL(_ value: String) -> URL? {
        guard value.utf8.count <= 16384, let c = URLComponents(string: value), c.scheme == "https", c.user == nil, c.password == nil, c.port == nil || c.port == 443, c.fragment == nil, let host = c.host?.lowercased(), host == "vk.ru" || host == "vk.com" || host.hasSuffix(".vk.ru") || host.hasSuffix(".vk.com") else { return nil }; return c.url
    }
}
