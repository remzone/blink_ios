import SwiftUI

struct SettingsView: View {
    @State private var guidePresented = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "bolt.shield.fill").font(.system(size: 30, weight: .medium))
                        .foregroundStyle(BlinkTheme.primaryFill).frame(width: 68, height: 68)
                        .background(BlinkTheme.ink, in: RoundedRectangle(cornerRadius: 22))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blink").font(.system(.title2, design: .rounded).weight(.bold))
                        Text("Ваша сеть, под вашим контролем").font(.caption).foregroundStyle(.secondary)
                        Text("Версия \(version) · сборка \(build)").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section("Подключение") {
                NavigationLink { RoutingSettingsView() } label: { settingsRow("Маршрутизация", detail: "Правила панели и свои исключения", symbol: "arrow.triangle.branch", color: BlinkTheme.accent) }
                settingsRow("Параметры из подписки", detail: "Транспорт и протокол задаёт провайдер в панели", symbol: "checkmark.shield.fill", color: BlinkTheme.vk)
            }
            Section("Помощь и диагностика") {
                Button { guidePresented = true } label: {
                    settingsRow("Режимы и конфигурации", detail: "Обычный VPN, TURN и типы профилей", symbol: "questionmark.circle.fill", color: BlinkTheme.vk)
                }.foregroundStyle(.primary)
                NavigationLink { LogsView() } label: {
                    settingsRow("Журнал событий", detail: "Сообщения, сохранённые приложением", symbol: "text.alignleft", color: BlinkTheme.ice)
                }
            }
            Section("На вашем устройстве") {
                settingsRow("Защищённое хранение", detail: "Ссылки и ключи находятся в Keychain", symbol: "lock.fill", color: BlinkTheme.accent)
                settingsRow("Системное оформление", detail: "Тема и размер текста следуют iOS", symbol: "circle.lefthalf.filled", color: BlinkTheme.ice)
                settingsRow("Бережные анимации", detail: "Учитывается «Уменьшение движения»", symbol: "figure.walk", color: BlinkTheme.vk)
            }
            Section {
                Text("Blink подключается к серверам из ваших конфигураций. Подписки и доступ к серверам предоставляет ваш провайдер.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.listStyle(.insetGrouped).blinkScreen().navigationTitle("Настройки").navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $guidePresented) { ProtocolGuideView() }
    }
    private func settingsRow(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                .frame(width: 32, height: 32).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 5)
    }
}
