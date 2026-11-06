import Foundation
import Combine
import BlinkCore
import VKCaptchaSDK

/// Runs in the foreground app before starting NE routes. No challenge/token is persisted.
@MainActor
final class VKPreflightAuthorizer: NSObject, ObservableObject, MobilePacketWriterProtocol {
    struct LegacyChallenge: Identifiable { let id: String; let image: URL }
    @Published var legacy: LegacyChallenge?
    private let protector = XraySocketProtector()
    private var engine: MobileEngine?
    private var sdk: VKCaptcha?
    private var attempt = UUID()
    private var answer: CheckedContinuation<String, Error>?
    private var timer: Task<Void, Never>?
    nonisolated func writePacket(_ packet: Data?) -> Bool { true }

    func authorize(_ json: String) async throws -> String {
        guard engine == nil else { throw failure("Проверка VK уже выполняется.") }
        let id = UUID(); attempt = id; protector.start()
        var error: NSError?; engine = MobileStartVK(json, self, protector, &error)
        guard error == nil, engine != nil else { engine?.stop(); engine = nil; protector.stop(); throw failure("Не удалось начать авторизацию VK.") }
        defer { cancel() }
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            guard attempt == id, let engine else { throw CancellationError() }
            switch engine.status() {
            case "ready":
                let handoff = engine.exportVKBootstrap()
                guard !handoff.isEmpty else { throw failure("Реквизиты VK не готовы. Повторите подключение.") }
                return handoff
            case "captcha_required":
                let data = Data(engine.captchaJSON().utf8)
                struct Challenge: Decodable { let id: String; let url: String?; let image: String?; let expires_at: Int64 }
                let challenge = try JSONDecoder().decode(Challenge.self, from: data)
                guard challenge.expires_at > Int64(Date().timeIntervalSince1970) else { throw failure("Проверка VK истекла.") }
                let token: String; let kind: String
                if let value = challenge.url, let url = trustedURL(value) {
                    kind = "token"; token = try await solve(url, seconds: max(1, challenge.expires_at - Int64(Date().timeIntervalSince1970)))
                } else if let value = challenge.image, let url = trustedURL(value) {
                    kind = "key"; token = try await legacyAnswer(id: challenge.id, image: url, seconds: max(1, challenge.expires_at - Int64(Date().timeIntervalSince1970)))
                } else { throw failure("VK не выдал поддерживаемую ручную проверку.") }
                guard attempt == id, engine.submitCaptcha(challenge.id, kind: kind, value: token) else { throw failure("Проверка истекла. Подключитесь заново.") }
            case "stopped": throw failure("Авторизация VK остановлена.")
            default: try await Task.sleep(for: .seconds(1))
            }
        }
        throw failure("Время авторизации VK истекло.")
    }
    func cancel() {
        attempt = UUID(); sdk?.closeCaptcha(animated: false, completion: nil); sdk = nil
        finish(.failure(CancellationError())); legacy = nil
        engine?.stop(); engine = nil; protector.stop()
    }
    func submitLegacy(_ code: String) { finish(.success(code)); legacy = nil }
    func cancelLegacy() { finish(.failure(CancellationError())); legacy = nil }
    private func legacyAnswer(id: String, image: URL, seconds: Int64) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in answer = continuation; legacy = .init(id: id, image: image); expire(after: seconds) }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancelLegacy() } })
    }
    private func solve(_ url: URL, seconds: Int64) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                answer = continuation
                let captcha = VKCaptcha(configuration: .init(url: url, theme: .system)); sdk = captcha
                let current = attempt
                captcha.openCaptcha(presenter: VKCaptchaNewUIWindowPresenter()) { [weak self, weak captcha] result in
                    Task { @MainActor in
                        guard let self, self.attempt == current, self.sdk === captcha else { return }
                        switch result { case .success(let token): self.finish(.success(token)); case .failure: self.finish(.failure(CancellationError())) }
                    }
                }
                expire(after: seconds)
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
    private func expire(after seconds: Int64) {
        timer?.cancel(); let id = attempt
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.attempt == id else { return }
            self.finish(.failure(self.failure("Проверка VK истекла."))); self.legacy = nil
            self.sdk?.closeCaptcha(animated: false, completion: nil)
        }
    }
    private func finish(_ result: Result<String, Error>) { timer?.cancel(); timer = nil; let continuation = answer; answer = nil; continuation?.resume(with: result) }
    private func trustedURL(_ value: String) -> URL? {
        guard value.utf8.count <= 16384, let c = URLComponents(string: value), c.scheme == "https", c.user == nil, c.password == nil, c.port == nil || c.port == 443, c.fragment == nil, let host = c.host?.lowercased(), host == "vk.ru" || host == "vk.com" || host.hasSuffix(".vk.ru") || host.hasSuffix(".vk.com") else { return nil }; return c.url
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "Blink.VK", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
