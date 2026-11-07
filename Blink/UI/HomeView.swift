import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var xray: XrayVPNController
    @EnvironmentObject private var navigation: BlinkNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var guidePresented = false
    private var displayedRoute: ConnectionRoute { xray.hasActiveConnection ? (xray.route ?? .direct) : navigation.route }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    masthead
                    if geometry.size.width >= 850 && !typeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 24) { connection; nextSteps }
                    } else { connection; nextSteps }
                    if let error = xray.errorMessage { BlinkNotice(message: error, symbol: "exclamationmark.circle").transition(.opacity) }
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                        Text("Конфигурации хранятся в защищённом хранилище устройства.")
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(geometry.size.width < 360 ? 16 : 22).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.blinkScreen()
        }
        .navigationTitle("Blink").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $guidePresented) { ProtocolGuideView() }
        .animation(reduceMotion ? nil : BlinkTheme.spring, value: xray.hasActiveConnection)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await xray.refreshTransportStatus()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private var masthead: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Ваша сеть,\nпод вашим контролем.")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-1)
                Text("Выберите маршрут. Остальное — в Blink.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { guidePresented = true } label: {
                Image(systemName: "questionmark").font(.headline).frame(width: 44, height: 44)
                    .background(BlinkTheme.surface, in: Circle())
            }.accessibilityLabel("Как работают обычный VPN и VK")
        }.padding(.vertical, 8)
    }
    private var connection: some View {
        VStack(spacing: 18) {
            HStack {
                Label("BLINK CONNECT", systemImage: "sparkle").font(.caption2.weight(.bold)).tracking(1.8)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(xray.isConnected ? BlinkTheme.primaryFill : .white.opacity(0.5)).frame(width: 6, height: 6)
                    Text(xray.isConnected ? "VPN включён" : xray.isConnecting ? "Подключение" : xray.isDisconnecting ? "Отключение" : "VPN выключен")
                        .font(.caption.weight(.medium))
                }
            }.foregroundStyle(.white.opacity(0.72))
            Button { primaryAction() } label: {
                BlinkOrbit(connected: xray.isConnected, busy: xray.isConnecting, color: displayedRoute == .vk ? Color(red: 0.69, green: 0.72, blue: 1) : BlinkTheme.primaryFill)
                    .frame(maxWidth: 210).frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.plain).disabled(xray.isDisconnecting)
                .accessibilityLabel(primaryTitle)
            VStack(spacing: 7) {
                Text(xray.isConnected ? "Подключение активно" : xray.isConnecting ? "Настраиваем маршрут" : xray.isDisconnecting ? "Завершаем соединение" : "Готовы подключиться?")
                    .font(.system(.title2, design: .rounded).weight(.bold)).multilineTextAlignment(.center)
                Text(xray.hasActiveConnection ? xray.profileName : "Добавьте свой сервер или подписку")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(.white)
            Label(displayedRoute.title, systemImage: displayedRoute.symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 13).padding(.vertical, 8).background(.white.opacity(0.09), in: Capsule())
            Button { primaryAction() } label: { Label(primaryTitle, systemImage: xray.hasActiveConnection ? "power" : "arrow.right") }
                .buttonStyle(BlinkActionStyle(prominent: true, color: displayedRoute == .vk ? Color(red: 0.72, green: 0.75, blue: 1) : BlinkTheme.primaryFill))
                .disabled(xray.isDisconnecting)
            Text(xray.hasActiveConnection ? xray.status : "Подключение начнётся после выбора сервера")
                .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).accessibilityLabel("Состояние: \(xray.status)")
        }.padding(24).frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 32, style: .continuous).fill(BlinkTheme.ink)
                    .overlay {
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .fill(RadialGradient(colors: [(displayedRoute == .vk ? BlinkTheme.vk : BlinkTheme.accent).opacity(0.25), .clear], center: .topTrailing, startRadius: 0, endRadius: 380))
                    }
            }
            .overlay { RoundedRectangle(cornerRadius: 32).strokeBorder(.white.opacity(0.08)) }
    }
    private var primaryTitle: String {
        xray.isDisconnecting ? "Отключаем…" : xray.isConnecting ? "Отменить подключение" : xray.isConnected ? "Отключить" : "Выбрать сервер"
    }
    private func primaryAction() {
        if xray.hasActiveConnection { xray.disconnect() }
        else { navigation.openLibrary(navigation.route) }
    }
    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            BlinkSectionHeading(title: "Как подключаться")
            routeCard(.direct, detail: "Ваш сервер и привычные конфигурации. Без VK и CAPTCHA.")
            routeCard(.vk, detail: "Альтернативный маршрут с подпиской Vokop и проверкой VK.")
            Button { navigation.tab = .diagnostics } label: {
                BlinkDestination(title: "Проверить соединение", subtitle: "Ваш IP и доступ к сервисам", symbol: "waveform.path.ecg")
            }.buttonStyle(.plain).blinkCard()
            Button { guidePresented = true } label: {
                Label("Чем отличаются режимы и конфиги?", systemImage: "info.circle")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }.frame(maxWidth: .infinity)
    }
    private func routeCard(_ route: ConnectionRoute, detail: String) -> some View {
        Button { navigation.openLibrary(route) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    BlinkBadge(symbol: route.symbol, color: route.color)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold)).foregroundStyle(route.color)
                }
                Text(route.title).font(.title3.weight(.bold)).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
        }.buttonStyle(BlinkTileStyle())
    }
}
