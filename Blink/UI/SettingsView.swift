import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            NavigationLink { LogsView() } label: { Label("Журнал", systemImage: "doc.text.magnifyingglass") }
            Section("О приложении") {
                LabeledContent("Приложение", value: "Blink")
                LabeledContent("Протоколы", value: "Xray / WireGuard / AmneziaWG / VK TURN")
                LabeledContent("Минимальная iOS", value: "16.0")
            }
            Section { Text("Ссылки подписок и конфигурации хранятся в защищённом хранилище устройства.").foregroundStyle(.secondary) }
        }.navigationTitle("Настройки").blinkScreen()
    }
}
