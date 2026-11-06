import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var xray: XrayVPNController
    @StateObject private var diagnostics = NetworkDiagnostics()
    var body: some View {
        List {
            Section("Внешний IP") {
                check("Мой IP · обычная сеть", icon: "wifi", kind: "ip", direct: true)
                check("IP туннеля", icon: "shield.lefthalf.filled", kind: "ip", direct: false)
            }
            Section("Доступ через туннель") {
                check("Google · HTTPS-пинг", icon: "network", kind: "google", direct: false)
                check("YouTube", icon: "play.rectangle", kind: "youtube", direct: false)
            }
            Section {
                Text("Мой IP проверяется напрямую только по нажатию. Проверки туннеля требуют активного VPN и не переключаются на обычную сеть при ошибке. HTTPS-пинг измеряет DNS, TCP, TLS и ответ сервиса; это не ICMP и не замер скорости видео.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Диагностика").blinkScreen()
    }
    private func check(_ title: String, icon: String, kind: String, direct: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { Task { await diagnostics.check(kind: kind, direct: direct, vpn: xray) } } label: { Label(title, systemImage: icon) }.disabled(diagnostics.busy)
            Text(diagnostics.results[direct ? "direct" : kind] ?? "Ещё не проверен").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(.vertical, 8)
    }
}
