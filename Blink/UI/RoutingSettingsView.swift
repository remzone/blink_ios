import SwiftUI

struct RoutingSettingsView: View {
    @EnvironmentObject private var xray: XrayVPNController
    @State private var settings = LocalRoutingSettings.load()
    @State private var policy = LocalRoutingSettings.cachedPolicy()
    @State private var message: String?
    @State private var reset = false
    var body: some View {
        Form {
            Section {
                Label("Интернет по вашим правилам", systemImage: "arrow.triangle.branch")
                    .font(.title3.weight(.semibold))
                Text("В выборочном режиме только адреса из списка идут через VPN. Остальные соединения выходят напрямую с вашего устройства.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Политика панели") {
                if let policy {
                    LabeledContent("Режим", value: policy.mode == "selected" ? "Выборочно" : "Весь трафик")
                    LabeledContent("Домены", value: "\(policy.domains.count)")
                    LabeledContent("Подсети и IP", value: "\(policy.ips.count)")
                    Text("Обновлено \(Date(timeIntervalSince1970: TimeInterval(policy.updated_at)).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Посмотреть серверный список") { List { Section("VPN · домены") { ForEach(policy.domains, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } }; Section("VPN · подсети") { ForEach(policy.ips, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } } }.navigationTitle("Правила панели") }
                } else { Text("Обновите подписку Vokop, чтобы получить правила панели. Собственные списки можно задать ниже.").foregroundStyle(.secondary) }
            }
            Section("На этом устройстве") {
                Picker("Режим", selection: $settings.mode) {
                    Text("Как в панели").tag("inherit")
                    Text("Выборочно").tag("selected")
                    Text("Весь трафик через VPN").tag("all")
                }
                Text("Свои правила дополняют серверные. Исключения имеют приоритет; поддомены включаются автоматически.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Дополнительно через VPN") {
                TextEditor(text: $settings.include).frame(minHeight: 120).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("example.org или 203.0.113.0/24 · по одному на строке").font(.caption).foregroundStyle(.secondary)
            }
            Section("Всегда напрямую") {
                TextEditor(text: $settings.exclude).frame(minHeight: 120).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Button("Сохранить правила") { do { try settings.save(); message = "Сохранено. Правила применятся при следующем подключении." } catch { message = error.localizedDescription } }
                Button("Вернуться к настройкам панели", role: .destructive) { reset = true }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if xray.hasActiveConnection { Text("Сначала отключите VPN для изменения правил.").font(.caption).foregroundStyle(.secondary) }
            }
            Section { Text("Поддерживаются VLESS и стандартный WireGuard, включая TURN. Для AmneziaWG и TUIC используйте режим «Весь трафик». Cloudflare содержит общие IP CDN: через VPN могут идти и другие сайты на тех же адресах.").font(.caption).foregroundStyle(.secondary) }
        }.disabled(xray.hasActiveConnection).navigationTitle("Маршрутизация")
            .confirmationDialog("Удалить свои исключения и использовать панель?", isPresented: $reset, titleVisibility: .visible) {
                Button("Сбросить", role: .destructive) { settings = .init(); do { try settings.save(); message = "Используются правила панели." } catch { message = error.localizedDescription } }
            }
    }
}
