import SwiftUI

private enum BlinkScreen: String, CaseIterable, Identifiable, Hashable {
    case home = "Главная", profiles = "VPN-профили", vokop = "Vokop", settings = "Настройки"
    var id: Self { self }
    var icon: String { switch self { case .home: return "house"; case .profiles: return "network"; case .vokop: return "person.crop.circle"; case .settings: return "gearshape" } }
}
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject private var xray: XrayVPNController
    @EnvironmentObject private var authorizer: VKPreflightAuthorizer
    @State private var selected: BlinkScreen? = .home
    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(BlinkScreen.allCases, selection: $selected) { screen in Label(screen.rawValue, systemImage: screen.icon).tag(screen) }.navigationTitle("Blink")
                } detail: { NavigationStack { destination(selected ?? .home) } }
            } else {
                TabView {
                    ForEach(BlinkScreen.allCases) { screen in NavigationStack { destination(screen) }.tabItem { Label(screen.rawValue, systemImage: screen.icon) } }
                }
            }
        }.tint(BlinkTheme.accent)
        .sheet(item: $authorizer.legacy, onDismiss: { authorizer.cancelLegacy() }) { challenge in LegacyVKCaptchaView(challenge: challenge) }
        .onChange(of: phase) { if $0 == .background { authorizer.cancel() } }
    }
    @ViewBuilder private func destination(_ screen: BlinkScreen) -> some View {
        switch screen { case .home: HomeView(); case .profiles: UniversalProfilesView(); case .vokop: SubscriptionView(); case .settings: SettingsView() }
    }
}
