import Foundation

/// Deliberately excludes NSError descriptions and URLs, which can contain subscription tokens.
enum NetworkRequestError: LocalizedError {
    case offline, timedOut, dns, tls, connection, httpStatus(Int)

    static func sanitized(_ error: Error) -> NetworkRequestError {
        guard let error = error as? URLError else { return .connection }
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .timedOut: return .timedOut
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired: return .tls
        default: return .connection
        }
    }

    var errorDescription: String? {
        switch self {
        case .offline: return "Нет доступа к интернету. Проверьте Wi-Fi и разрешение на сотовые данные для Blink."
        case .timedOut: return "Сервер не ответил вовремя. Повторите запрос или смените сеть."
        case .dns: return "Не удалось определить адрес сервера (DNS). Проверьте сеть и адрес подписки."
        case .tls: return "Не удалось проверить защищённое соединение (TLS). Проверьте дату устройства и сертификат сервера."
        case .connection: return "Не удалось соединиться с сервером. Попробуйте другую сеть."
        case .httpStatus(let code): return "Сервер вернул HTTP \(code). Проверьте подписку или повторите запрос позже."
        }
    }
}
