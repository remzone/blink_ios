import Foundation
import Combine
import BlinkCore

struct DiagnosticResult: Decodable {
    let kind: String; let direct: Bool; let ip: String?
    let dnsMs: Int?; let tcpMs: Int?; let tlsMs: Int?; let responseMs: Int?
    let totalMs: Int; let checkedAt: Int64
    var summary: String {
        var value = "\(ip ?? "Доступен") · \(totalMs) мс"
        if let dnsMs, let tcpMs, let tlsMs { value += "\nDNS \(dnsMs) · TCP \(tcpMs) · TLS \(tlsMs) мс" }
        return value
    }
}
@MainActor
final class NetworkDiagnostics: ObservableObject {
    @Published private(set) var results: [String: String] = [:]
    @Published private(set) var busy = false
    @Published private(set) var activeKey: String?
    func check(kind: String, direct: Bool, vpn: XrayVPNController) async {
        guard !busy else { return }
        guard !vpn.busy else { results[direct ? "direct" : kind] = "Дождитесь завершения подключения VPN."; return }
        let key = direct ? "direct" : kind
        guard direct || vpn.isConnected else { results[key] = "Сначала подключите туннель."; return }
        busy = true; activeKey = key; results[key] = "Проверяем…"
        defer { busy = false; activeKey = nil }
        // A physical bypass is only necessary while our VPN is active.
        // Ordinary requests use Apple's network stack, including DNS64/NAT64.
        let bypass = direct && vpn.isConnected
        let protector = XraySocketProtector()
        if bypass { protector.start() }
        defer { if bypass { protector.stop() } }
        do {
            let value: DiagnosticResult
            if bypass {
                let raw = try await Task.detached(priority: .userInitiated) {
                    var error: NSError?
                    let raw = MobileProbeInternet(kind, true, protector, &error)
                    guard error == nil else { throw UniversalProfileError.invalid }
                    return raw
                }.value
                value = try JSONDecoder().decode(DiagnosticResult.self, from: Data(raw.utf8))
            } else {
                value = try await SystemNetworkProbe.check(kind: kind, direct: direct)
            }
            try Task.checkCancellation()
            guard !direct || bypass || !vpn.isConnected else {
                results[key] = "VPN включился во время проверки. Повторите запрос для прямого IP."
                return
            }
            guard direct || vpn.isConnected else { results[key] = "VPN отключился во время проверки."; return }
            let date = Date(timeIntervalSince1970: TimeInterval(value.checkedAt))
            results[key] = value.summary + " · " + date.formatted(date: .omitted, time: .shortened)
        } catch is CancellationError { results[key] = "Проверка отменена." }
        catch let error as NetworkRequestError { results[key] = error.localizedDescription }
        catch { results[key] = "Проверка не прошла. Проверьте профиль и выбранную сеть." }
    }
}
