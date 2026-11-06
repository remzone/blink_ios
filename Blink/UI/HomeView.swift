import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var xray: XrayVPNController
    @ScaledMetric(relativeTo: .title) private var powerSize = 120
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Label("Blink", systemImage: "shield.lefthalf.filled").font(.largeTitle.bold())
                Image(systemName: "network.badge.shield.half.filled").font(.system(size: min(powerSize, 150))).foregroundStyle(.blue).accessibilityHidden(true)
                Text(xray.profileName).font(.title2).multilineTextAlignment(.center)
                Text(xray.status).font(.headline).multilineTextAlignment(.center)
                if xray.busy { ProgressView("Подготовка подключения…") }
                if let error = xray.errorMessage { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) }
                NavigationLink { UniversalProfilesView() } label: { Label("VPN-профили", systemImage: "network") }.buttonStyle(.borderedProminent).controlSize(.large)
                NavigationLink { SubscriptionView() } label: { Label("Подписка Vokop / VK TURN", systemImage: "person.crop.circle") }.buttonStyle(.bordered).controlSize(.large)
                Button("Отключить", role: .destructive) { xray.disconnect() }.buttonStyle(.bordered)
                Text("Обычные VPN-профили подключаются без VK. Системное подключение VPN ещё не подтверждает доступ к интернету.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }.navigationTitle("Главная")
            .task { while !Task.isCancelled { await xray.refreshTransportStatus(); try? await Task.sleep(for: .seconds(2)) } }
    }
}
