import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var xray: XrayVPNController
    @EnvironmentObject private var navigation: BlinkNavigation
    @StateObject private var diagnostics = NetworkDiagnostics()
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var columns: [GridItem] { textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 280), spacing: 16)] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlinkHeader(title: "Как работает сеть?", subtitle: "Проверьте маршрут и доступ к сервисам.")
                connectionSummary
                BlinkSectionHeading(title: "IP-адреса", detail: "Два разных маршрута")
                LazyVGrid(columns: columns, spacing: 16) {
                    check("IP вашей сети", subtitle: "Напрямую · Wi-Fi или сотовая сеть", icon: "wifi", kind: "ip", direct: true)
                    check("IP через VPN", subtitle: xray.route?.title ?? "Через выбранный сервер", icon: "shield.lefthalf.filled", kind: "ip", direct: false)
                }
                BlinkSectionHeading(title: "Доступность сервисов")
                LazyVGrid(columns: columns, spacing: 16) {
                    check("Google", subtitle: "HTTPS-запрос через VPN", icon: "globe", kind: "google", direct: false)
                    check("YouTube", subtitle: "HTTPS-запрос через VPN", icon: "play.rectangle.fill", kind: "youtube", direct: false)
                }
                DisclosureGroup("Что означают результаты") {
                    Text("IP вашей сети проверяется напрямую по вашему нажатию. Остальные запросы следуют маршрутам активного VPN. При раздельной маршрутизации часть адресов может идти напрямую. Проверка HTTPS показывает доступность сервиса, а не скорость загрузки или воспроизведения видео.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
                }.font(.subheadline.weight(.medium)).blinkCard()
            }.padding(20).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }.navigationTitle("Проверка сети").navigationBarTitleDisplayMode(.inline).blinkScreen()
    }
    private var connectionSummary: some View {
        HStack(spacing: 14) {
            BlinkBadge(symbol: xray.isConnected ? "checkmark.shield.fill" : "power", color: xray.route?.color ?? BlinkTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(xray.isConnected ? (xray.route?.title ?? "VPN включён") : "Сначала подключите VPN").font(.headline)
                Text(xray.isConnected ? "\(xray.profileName) · доступ в интернет проверяется ниже" : "IP вашей сети можно проверить и без подключения.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !xray.isConnected {
                Button { navigation.tab = .library } label: { Image(systemName: "arrow.right").frame(width: 40, height: 44) }.accessibilityLabel("Выбрать сервер")
            }
        }.blinkCard()
    }
    private func check(_ title: String, subtitle: String, icon: String, kind: String, direct: Bool) -> some View {
        let key = direct ? "direct" : kind
        let available = direct || xray.isConnected
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                BlinkBadge(symbol: icon, color: direct ? BlinkTheme.ice : (xray.route?.color ?? BlinkTheme.accent))
                Spacer()
                BlinkPill(title: direct ? "Без VPN" : "Через VPN", color: direct ? BlinkTheme.ice : (xray.route?.color ?? BlinkTheme.accent))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(diagnostics.results[key] ?? (available ? "Готово к проверке" : "Доступно после подключения VPN"))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 46, alignment: .topLeading)
            Button { Task { await diagnostics.check(kind: kind, direct: direct, vpn: xray) } } label: {
                HStack { if diagnostics.activeKey == key { ProgressView() }; Label(diagnostics.activeKey == key ? "Проверяем…" : "Проверить", systemImage: "arrow.clockwise") }
            }
                .buttonStyle(BlinkActionStyle()).disabled(diagnostics.busy || !available || xray.isConnecting)
        }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: diagnostics.results[key])
    }
}
