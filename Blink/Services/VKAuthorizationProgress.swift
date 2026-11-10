import Foundation

enum VKAuthorizationPhase: Equatable {
    case starting, captcha, verifying, transport, ready
    var diagnosticCode: Int64 {
        switch self { case .starting: return 0; case .captcha: return 1; case .verifying: return 2; case .transport: return 3; case .ready: return 4 }
    }
    var message: String {
        switch self {
        case .starting: return "Авторизация TURN · используется обычная сеть"
        case .captcha: return "Пройдите проверку TURN в открывшемся окне"
        case .verifying: return "Ответ CAPTCHA отправлен · ожидаем TURN"
        case .transport: return "TURN продолжает авторизацию · подключаем транспорт"
        case .ready: return "TURN готов · запускаем VPN"
        }
    }
}

/// The native worker consumes a submitted answer asynchronously. Until it does,
/// its status/challenge can still refer to the already completed CAPTCHA.
struct VKAuthorizationProgress {
    private(set) var submittedChallengeID: String?
    private(set) var responseDeadline: Date?

    mutating func submitted(_ id: String, now: Date = Date()) {
        submittedChallengeID = id
        responseDeadline = now.addingTimeInterval(60)
    }
    func shouldPresent(_ id: String) -> Bool { !id.isEmpty && id != submittedChallengeID }
    func responseTimedOut(now: Date = Date()) -> Bool { responseDeadline.map { now >= $0 } ?? false }
}

enum VKAuthorizationError: LocalizedError {
    case alreadyRunning, startFailed, expired, unsupportedChallenge, rejectedAnswer, stopped, transportTimedOut, invalidResponse
    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "Проверка TURN уже выполняется."
        case .startFailed: return "Не удалось начать авторизацию TURN. Проверьте сеть и повторите подключение."
        case .expired: return "Время проверки TURN истекло. Подключитесь заново."
        case .unsupportedChallenge: return "TURN не выдал поддерживаемую ручную проверку. Повторите подключение."
        case .rejectedAnswer: return "TURN не принял ответ CAPTCHA или проверка истекла. Подключитесь заново."
        case .stopped: return "Авторизация TURN остановлена. Повторите подключение."
        case .transportTimedOut: return "После CAPTCHA транспорт TURN не стал готов за 60 секунд. Попробуйте другую сеть или проверьте сервер и TCP/UDP."
        case .invalidResponse: return "Не удалось прочитать ответ проверки TURN. Повторите подключение."
        }
    }
}
