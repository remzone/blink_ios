import Foundation
import Combine
import BlinkCore

struct DiagnosticResult: Decodable {
    let kind: String; let direct: Bool; let ip: String?
    let dnsMs: Int?; let tcpMs: Int?; let tlsMs: Int?; let responseMs: Int?
    let totalMs: Int; let checkedAt: Int64
    var summary: String { "\(ip ?? "Доступен") · \(totalMs) мс\nDNS \(dnsMs ?? 0) · TCP \(tcpMs ?? 0) · TLS \(tlsMs ?? 0) мс" }
}
@MainActor
final class NetworkDiagnostics: ObservableObject {
    @Published private(set) var results: [String: String] = [:]
    @Published private(set) var busy = false
    func check(kind: String, direct: Bool, vpn: XrayVPNController) async {
        guard !busy else { return }
        let key = direct ? "direct" : kind
        guard direct || vpn.isConnected else { results[key] = "Сначала подключите туннель."; return }
        busy = true; results[key] = "Проверяем…"
        defer { busy = false }
        let protector = XraySocketProtector()
        if direct { protector.start() }
        defer { if direct { protector.stop() } }
        do {
            let raw = try await Task.detached(priority: .userInitiated) {
                var error: NSError?
                let raw = MobileProbeInternet(kind, direct, direct ? protector : nil, &error)
                guard error == nil else { throw UniversalProfileError.invalid }
                return raw
            }.value
            try Task.checkCancellation()
            guard direct || vpn.isConnected else { results[key] = "VPN отключился во время проверки."; return }
            let value = try JSONDecoder().decode(DiagnosticResult.self, from: Data(raw.utf8))
            let date = Date(timeIntervalSince1970: TimeInterval(value.checkedAt))
            results[key] = value.summary + " · " + date.formatted(date: .omitted, time: .shortened)
        } catch { results[key] = "Проверка не прошла. Проверьте профиль и выбранную сеть." }
    }
}
