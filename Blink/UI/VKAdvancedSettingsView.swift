import SwiftUI

struct VKAdvancedSettingsView: View {
    @EnvironmentObject private var xray: XrayVPNController
    @State private var options = VKConnectionOptions.load()
    var body: some View {
        Form {
            Section {
                Toggle("Настройки панели", isOn: Binding(get: { options.followsServer }, set: { options.serverDefaults = $0 }))
                Text("Включено: транспорт, число соединений, DNS и pacing берутся из подписки. Выключите для своих параметров. Тип VPN и протокол всегда задаёт серверный профиль.").font(.caption)
            }
            Section {
                Picker("До TURN-релея", selection: $options.transport) {
                    Text("Автоматически").tag("auto"); Text("UDP").tag("udp"); Text("TCP").tag("tcp")
                }
                TextField("TURN: host:port или [IPv6]:port", text: $options.turnServer)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("DNS до подключения", text: $options.bootstrapDNS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Label("Путь до TURN", systemImage: "arrow.triangle.branch") } footer: { Text("Для VLESS авто проверяет UDP и TCP до готовности DTLS/KCP/smux; для WG меняет TCP/UDP при ошибке сеанса. Релей по умолчанию выдаёт TURN; вручную нужен совместимый TURN с теми же учётными данными. Смена адреса не меняет способ авторизации на Яндекс или другой сервис.") }
            Section {
                Picker("Соединений с релеем", selection: $options.connections) {
                    Text("Как в подписке").tag(0)
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                }
            } header: { Label("Параллельные соединения", systemImage: "point.3.connected.trianglepath.dotted") } footer: { Text("По умолчанию — 1 для стабильности. Больше соединений может увеличить скорость, расход памяти и нагрузку на релей. Лимиты релея продолжают действовать.") }
            Section {
                Picker("Профиль KCP", selection: $options.preset) {
                    Text("Совместимость").tag("compatibility")
                    Text("Сбалансированный").tag("balanced")
                    Text("Бережный").tag("conservative")
                    Text("Вручную").tag("custom")
                }
                if options.preset == "custom" {
                    Stepper("Окно: \(options.window) пакетов", value: $options.window, in: 16...256, step: 16)
                    Stepper("Интервал: \(options.intervalMs) мс", value: $options.intervalMs, in: 10...100, step: 10)
                    Toggle("Контроль перегрузки", isOn: $options.congestion)
                }
                Stepper("MTU пакета KCP: \(options.mtu)", value: $options.mtu, in: 576...1200, step: 16)
            } header: { Label("Поведение транспорта", systemImage: "slider.horizontal.3") } footer: { Text("Совместимость сохраняет исходные настройки: окно 256, интервал 20 мс. Сбалансированный: окно 64 и контроль перегрузки. Бережный: окно 32, интервал 40 мс и контроль перегрузки. Меньшее окно и MTU помогают проверить потери, но могут снизить скорость. MTU интерфейса VPN остаётся 1280.") }
            Section {
                Picker("Исходящие на одно соединение", selection: $options.paceKiB) {
                    Text("Без ограничения").tag(0)
                    ForEach([64, 128, 256, 512, 1024], id: \.self) { Text("\($0) КиБ/с").tag($0) }
                }
            } header: { Label("Сглаживание всплесков", systemImage: "waveform.path") } footer: { Text("Распределяет исходящие пакеты во времени до отправки в DTLS. Может уменьшить потери на релеях с ограничением скорости; снижает максимум загрузки и добавляет задержку при насыщении. По умолчанию выключено.") }
            Section {
                Label("VLESS: KCP/smux · WG: DTLS / SRTP / WRAP", systemImage: "server.rack")
                Text("Тип и обёртка заданы подпиской и должны совпадать с сервером. WG-конфиг содержит отдельные ключи и адрес интерфейса. WRAP-A, WRAP-S и csqtt пока не поддерживаются.")
                Label("CAPTCHA: пройти проверку вручную", systemImage: "person.crop.rectangle.badge.checkmark")
                Text("Если TURN запросит проверку, приложение откроет её для вас перед запуском VPN.")
            }.font(.footnote).foregroundStyle(.secondary)
            if !options.isValid {
                Label("Проверьте IP-адрес DNS и TURN в формате host:port. Некорректные изменения не сохраняются.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Section {
                Button("Восстановить исходные настройки", role: .destructive) { options = VKConnectionOptions() }
                Text("Применяются при следующем подключении. Авто выбирает доступный транспорт; профиль KCP задаётся вручную.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(xray.hasActiveConnection)
        .navigationTitle("Настройки TURN").navigationBarTitleDisplayMode(.inline)
        .onChange(of: options) { $0.save() }
    }
}
