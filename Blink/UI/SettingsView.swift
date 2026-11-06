import SwiftUI

struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlinkHeader(title: "Всё на своих местах.", subtitle: "Немного о Blink и твоём устройстве.")
                NavigationLink { LogsView() } label: { BlinkDestination(title: "История соединений", subtitle: "Что происходило с подключением", symbol: "text.alignleft") }.buttonStyle(BlinkActionStyle())
                VStack(alignment: .leading, spacing: 18) {
                    BlinkBadge(symbol: "sparkles")
                    Text("Просто Blink").font(.title2.weight(.semibold))
                    Text("Одно место для твоих подключений. На большом экране, планшете или в кармане.").foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Платформа", value: "iOS / iPadOS 16+")
                    LabeledContent("Подключения", value: "Xray · WireGuard · AmneziaWG · VK TURN")
                }.blinkCard()
                BlinkNotice(message: "Ссылки подписок и конфигурации находятся в защищённом хранилище. Ключи не передаются в интерфейс лаунчера.", symbol: "lock.shield")
                BlinkNotice(message: "Blink уважает системную настройку «Уменьшение движения». Размер текста и светлая или тёмная тема следуют настройкам устройства.", symbol: "accessibility")
            }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline).blinkScreen()
    }
}
