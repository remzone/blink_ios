import SwiftUI

struct BlinkPill: View {
    let title: String
    var symbol: String? = nil
    var color: Color = BlinkTheme.accent
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }.font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.11), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct BlinkSectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.padding(.top, 6)
    }
}

struct RouteExplainer: View {
    let route: ConnectionRoute
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(reduceMotion ? nil : BlinkTheme.spring) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    BlinkBadge(symbol: route.symbol, color: route.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(route.title).font(.headline).foregroundStyle(.primary)
                        Text(route.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(route.title). \(route.subtitle). \(expanded ? "Свернуть пояснение" : "Как это работает")")
            if expanded {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { pathNodes }
                    VStack(alignment: .leading, spacing: 10) { pathNodes }
                }.font(.caption.weight(.medium))
                Text(route == .direct
                     ? "Добавьте конфигурацию своего провайдера. Blink подключится к его серверу без участия VK."
                     : "Нужна подписка Vokop. Сначала Blink пройдёт авторизацию VK, затем запустит VPN через VK TURN.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
    }
    @ViewBuilder private var pathNodes: some View {
        Label("Устройство", systemImage: "iphone")
        Image(systemName: "arrow.right").foregroundStyle(route.color).accessibilityHidden(true)
        if route == .vk {
            Text("VK TURN").foregroundStyle(route.color)
            Image(systemName: "arrow.right").foregroundStyle(route.color).accessibilityHidden(true)
        }
        Label("Ваш сервер", systemImage: "server.rack")
    }
}

struct ActiveConnectionCard: View {
    @EnvironmentObject private var xray: XrayVPNController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                BlinkBadge(symbol: xray.route?.symbol ?? "power", color: xray.route?.color ?? BlinkTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(xray.hasActiveConnection ? (xray.route?.title ?? "Подключение") : "VPN выключен").font(.headline)
                    Text(xray.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if xray.isConnecting || xray.isDisconnecting { ProgressView() }
            }
            if let error = xray.errorMessage { BlinkNotice(message: error, symbol: "exclamationmark.circle") }
            if xray.hasActiveConnection {
                Text("Чтобы выбрать другой сервер или режим, сначала отключите текущее соединение.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { xray.disconnect() } label: {
                    Label(xray.isConnecting ? "Отменить подключение" : "Отключить", systemImage: "power")
                }.buttonStyle(BlinkActionStyle()).disabled(xray.isDisconnecting)
            }
        }.blinkCard()
    }
}

struct ProtocolGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Два способа подключения") {
                    guide("Обычный VPN", icon: "bolt.shield.fill", color: BlinkTheme.accent, text: "Ваше устройство подключается к серверу из конфигурации. Подходят ссылки VLESS, VMess, Trojan, Shadowsocks, профили WireGuard и другие поддерживаемые форматы.")
                    guide("Через VK", icon: "arrow.triangle.branch", color: BlinkTheme.vk, text: "VLESS передаётся через VK TURN. Для этого режима нужна отдельная подписка Vokop. При подключении VK может попросить CAPTCHA.")
                }
                Section("Что вы получили от провайдера") {
                    guide("Ссылка на сервер", icon: "link", color: BlinkTheme.accent, text: "Например, vless:// или trojan://. Содержит настройки одного сервера; добавляйте в обычный VPN.")
                    guide("Ссылка на подписку", icon: "rectangle.stack", color: BlinkTheme.accent, text: "HTTPS-ссылка может содержать несколько серверов. После импорта их можно обновить из библиотеки. Обычные подписки и Vokop используют разные форматы.")
                    guide("Файл или QR", icon: "qrcode", color: BlinkTheme.accent, text: "QR может содержать ссылку или сам конфиг. Файлы JSON, YAML и .conf распознаются импортёром; неподдерживаемые настройки не применяются молча.")
                }
                Section("Нужно ли выбирать протокол?") {
                    Text("Обычно нет: он уже указан в конфигурации провайдера. VLESS, WireGuard и другие подписи на карточках объясняют тип подключения. Самостоятельная смена протокола не превращает один конфиг в другой.")
                        .font(.subheadline)
                }
            }.listStyle(.insetGrouped).blinkScreen()
                .navigationTitle("Как это устроено").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
    private func guide(_ title: String, icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BlinkBadge(symbol: icon, color: color)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 8)
    }
}

struct ProfileDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: UniversalProfile
    private var info: VPNProtocolInfo { .describe(kind: profile.kind, source: profile.source) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        BlinkBadge(symbol: info.symbol)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.headline)
                            Text(info.title).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                    Text(info.summary).font(.subheadline)
                }
                Section("Подключение") {
                    LabeledContent("Режим", value: "Обычный VPN")
                    LabeledContent("Семейство", value: info.family)
                    LabeledContent("VK и CAPTCHA", value: "Не используются")
                    LabeledContent("Источник", value: profile.subscriptionURL.flatMap { URLComponents(string: $0)?.host } ?? "Отдельная конфигурация")
                }
                Section {
                    Text("Режим подключения и протокол — разные вещи. Этот профиль подключается к серверу напрямую. Для маршрута через VK нужна подписка Vokop в разделе «Через VK».")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.listStyle(.insetGrouped).blinkScreen().navigationTitle("О конфигурации").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

struct VKJourneyView: View {
    @EnvironmentObject private var xray: XrayVPNController
    private var stage: Int {
        if xray.isConnected { return 3 }
        switch xray.authorizationPhase {
        case .starting: return 0
        case .captcha: return 1
        case .verifying, .transport, .ready: return 2
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Подключение через VK").font(.headline)
            step(0, title: "Авторизация VK", detail: "В обычной сети, до запуска VPN")
            step(1, title: "Ручная проверка", detail: "Только если VK запросит CAPTCHA")
            step(2, title: "Запуск VPN", detail: xray.isConnected ? "Туннель включён" : "Ожидаем готовности транспорта")
        }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
    }
    private func step(_ index: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(BlinkTheme.vk.opacity(index <= stage ? 0.15 : 0.05)).frame(width: 30, height: 30)
                if index < stage { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(BlinkTheme.vk) }
                else if index == stage { ProgressView().scaleEffect(0.75).tint(BlinkTheme.vk) }
                else { Text("\(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}
