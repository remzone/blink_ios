import SwiftUI

struct DiagnosticsView: View {
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var textSize
    private var gridColumns: [GridItem] { widthClass == .compact || textSize.isAccessibilitySize ? [GridItem(.flexible(minimum: 0))] : [GridItem(.adaptive(minimum: 250), spacing: 18)] }
    @EnvironmentObject private var xray: XrayVPNController
    @StateObject private var diagnostics = NetworkDiagnostics()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlinkHeader(title: "Как чувствует\nсебя сеть?", subtitle: "Маршрут, задержка и доступ к любимым сервисам.")
                LazyVGrid(columns: gridColumns, spacing: 18) {
                    check("Мой IP", subtitle: "Обычная сеть · напрямую", icon: "wifi", kind: "ip", direct: true)
                    check("IP туннеля", subtitle: "Выход выбранного сервера", icon: "shield.lefthalf.filled", kind: "ip", direct: false)
                    check("Google", subtitle: "Проверка HTTPS-ответа", icon: "globe", kind: "google", direct: false)
                    check("YouTube", subtitle: "Доступность сервиса", icon: "play.rectangle", kind: "youtube", direct: false)
                }
                BlinkNotice(message: "Мой IP проверяется напрямую по твоему нажатию. Остальные проверки идут через активный VPN. HTTPS-пинг — не ICMP и не замер скорости видео.")
            }.padding(22).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.navigationTitle("Диагностика").navigationBarTitleDisplayMode(.inline).blinkScreen()
    }
    private func check(_ title: String, subtitle: String, icon: String, kind: String, direct: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            BlinkBadge(symbol: icon)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Text(diagnostics.results[direct ? "direct" : kind] ?? "Пока не проверяли").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).frame(minHeight: 46, alignment: .topLeading)
            Button { Task { await diagnostics.check(kind: kind, direct: direct, vpn: xray) } } label: { Label("Проверить", systemImage: "arrow.clockwise") }.buttonStyle(BlinkActionStyle()).disabled(diagnostics.busy)
        }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: diagnostics.results[direct ? "direct" : kind])
    }
}
