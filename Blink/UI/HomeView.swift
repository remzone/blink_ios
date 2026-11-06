import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var xray: XrayVPNController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    BlinkHeader(title: "Твоя сеть.\nТвои правила.", subtitle: "Один Blink — и ты на связи.")
                    if geometry.size.width >= 800 && !typeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 24) { connection.frame(maxWidth: .infinity); destinations.frame(maxWidth: .infinity) }
                    } else { connection; destinations }
                    if let error = xray.errorMessage { BlinkNotice(message: error, symbol: "exclamationmark.circle").transition(.opacity) }
                    Label("Твои ключи остаются на твоём устройстве.", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(geometry.size.width < 360 ? 16 : 28).frame(maxWidth: 1120).frame(maxWidth: .infinity)
            }.blinkScreen()
        }.navigationTitle("Главная").navigationBarTitleDisplayMode(.inline)
            .animation(reduceMotion ? nil : BlinkTheme.spring, value: xray.busy)
            .animation(reduceMotion ? nil : BlinkTheme.spring, value: xray.isConnected)
            .task { while !Task.isCancelled { await xray.refreshTransportStatus(); try? await Task.sleep(for: .seconds(2)) } }
    }
    private var connection: some View {
        VStack(spacing: 18) {
            Text("ПРОСТО БУДЬ НА СВЯЗИ").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
            BlinkOrbit(connected: xray.isConnected, busy: xray.busy)
            Text(xray.isConnected ? "Ты на связи" : xray.busy ? "Соединяем…" : "Всё начинается здесь").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(xray.profileName).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if xray.busy { ProgressView().accessibilityLabel("Подготовка подключения") }
            if xray.isConnected {
                Button { xray.disconnect() } label: { Label("Отключить туннель", systemImage: "power") }.buttonStyle(BlinkActionStyle(prominent: true))
            } else {
                NavigationLink { UniversalProfilesView() } label: { Label("Выбрать сервер", systemImage: "globe.europe.africa") }.buttonStyle(BlinkActionStyle(prominent: true)).disabled(xray.busy)
            }
            Text(xray.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).accessibilityLabel("Состояние: \(xray.status)")
        }.frame(maxWidth: .infinity).blinkCard()
    }
    private var destinations: some View {
        VStack(spacing: 16) {
            NavigationLink { UniversalProfilesView() } label: { BlinkDestination(title: "Твой мир", subtitle: "Серверы, страны и подписки", symbol: "globe.europe.africa") }.buttonStyle(BlinkActionStyle())
            NavigationLink { SubscriptionView() } label: { BlinkDestination(title: "Через VK", subtitle: "Подключение с подпиской Vokop", symbol: "arrow.triangle.branch") }.buttonStyle(BlinkActionStyle())
            NavigationLink { DiagnosticsView() } label: { BlinkDestination(title: "Как связь?", subtitle: "IP, Google и доступ к YouTube", symbol: "waveform.path.ecg") }.buttonStyle(BlinkActionStyle())
            BlinkNotice(message: "Значок VPN — это начало. Проверить доступ к сайтам можно в диагностике.")
        }
    }
}
