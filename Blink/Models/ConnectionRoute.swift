import Foundation

enum ConnectionRoute: String, CaseIterable, Identifiable {
    case direct, vk
    var id: String { rawValue }
    static func fromProviderMode(_ mode: String?) -> ConnectionRoute { mode == "vkturn" ? .vk : .direct }
    var title: String { self == .direct ? "Обычный VPN" : "TURN" }
    var subtitle: String { self == .direct ? "Напрямую к серверу" : "Маршрут через TURN" }
    var symbol: String { self == .direct ? "bolt.shield.fill" : "arrow.triangle.branch" }
}

struct VPNProtocolInfo {
    let title: String
    let family: String
    let summary: String
    let symbol: String

    static func describe(kind: String, source: String) -> VPNProtocolInfo {
        switch kind {
        case "wireguard": return .init(title: "WireGuard", family: "VPN-туннель", summary: "Подключение к WireGuard-серверу. Адреса, DNS и маршруты заданы в конфигурации.", symbol: "network")
        case "amneziawg": return .init(title: "AmneziaWG", family: "VPN-туннель", summary: "Вариант WireGuard с дополнительными параметрами маскировки. Сервер должен поддерживать AmneziaWG.", symbol: "shield.lefthalf.filled")
        case "xray-json": return .init(title: "Xray JSON", family: "Готовая конфигурация", summary: "Конфигурация Xray со своими протоколами, DNS и правилами маршрутизации. Blink сохраняет поддерживаемые настройки документа.", symbol: "curlybraces")
        case "tuic": return .init(title: "TUIC", family: "Прокси через QUIC", summary: "Подключение TUIC v5 к серверу провайдера. Для этого транспорта в сети должен быть доступен UDP.", symbol: "bolt.horizontal.fill")
        case "hysteria1": return .init(title: "Hysteria", family: "Прокси через QUIC", summary: "Профиль Hysteria первой версии. Требует совместимого сервера и доступа к UDP.", symbol: "wind")
        default: break
        }
        // Only inspect the URI scheme; never expose credentials or URI query values.
        let scheme = source.components(separatedBy: "://").first?.lowercased() ?? ""
        switch scheme {
        case "vless": return .init(title: "VLESS", family: "Xray", summary: "Подключение к VLESS-серверу. TLS, Reality и транспорт зависят от настроек, которые выдал провайдер.", symbol: "bolt.shield.fill")
        case "vmess": return .init(title: "VMess", family: "Xray", summary: "Профиль VMess AEAD. Адрес сервера и параметры подключения уже находятся в ссылке.", symbol: "square.stack.3d.up.fill")
        case "trojan": return .init(title: "Trojan", family: "Xray", summary: "Подключение к Trojan-серверу с параметрами TLS из конфигурации провайдера.", symbol: "lock.shield.fill")
        case "ss": return .init(title: "Shadowsocks", family: "Xray", summary: "Прокси Shadowsocks. Метод шифрования и пароль заданы провайдером.", symbol: "paperplane.fill")
        case "hy2", "hysteria2": return .init(title: "Hysteria 2", family: "Xray · QUIC", summary: "Подключение Hysteria 2. Для работы транспорта в сети должен быть доступен UDP.", symbol: "wind")
        case "socks", "socks5": return .init(title: "SOCKS", family: "Прокси", summary: "Подключение к SOCKS-прокси. Сам протокол не добавляет шифрование между устройством и прокси.", symbol: "arrow.left.arrow.right")
        case "http", "https": return .init(title: "HTTP CONNECT", family: "Прокси", summary: "Прокси с методом CONNECT. Защита соединения зависит от параметров выданного профиля.", symbol: "globe")
        default: return .init(title: "VPN-профиль", family: "Импортированная конфигурация", summary: "Конфигурация из вашей библиотеки. Параметры подключения определяются её настройками.", symbol: "shield.fill")
        }
    }
}
