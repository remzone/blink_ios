import SwiftUI

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject private var authorizer: VKPreflightAuthorizer
    @StateObject private var navigation = BlinkNavigation()
    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(selection: Binding<BlinkTab?>(get: { navigation.tab }, set: { if let tab = $0 { navigation.tab = tab } })) {
                        Section {
                            ForEach(BlinkTab.allCases) { tab in
                                Label(tab.title, systemImage: tab.symbol).tag(tab)
                            }
                        } header: {
                            Text("ВАША СЕТЬ").font(.caption2.weight(.semibold)).tracking(2)
                        }
                    }.navigationTitle("Blink").listStyle(.sidebar).blinkScreen()
                } detail: {
                    NavigationStack { destination(navigation.tab) }.id(navigation.tab)
                }
            } else {
                TabView(selection: $navigation.tab) {
                    ForEach(BlinkTab.allCases) { tab in
                        NavigationStack { destination(tab) }
                            .tabItem { Label(tab.title, systemImage: tab.symbol) }.tag(tab)
                    }
                }
            }
        }
        .environmentObject(navigation)
        .tint(BlinkTheme.accent)
        .sheet(item: $authorizer.modern) { challenge in ModernVKCaptchaView(challenge: challenge) }
        .sheet(item: $authorizer.legacy) { challenge in LegacyVKCaptchaView(challenge: challenge) }
        .onChange(of: phase) { if $0 == .background { authorizer.cancel() } }
    }
    @ViewBuilder private func destination(_ tab: BlinkTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .library: ConnectionsView()
        case .diagnostics: DiagnosticsView()
        case .settings: SettingsView()
        }
    }
}

struct ConnectionsView: View {
    @EnvironmentObject private var navigation: BlinkNavigation
    var body: some View {
        Group {
            switch navigation.route {
            case .direct: UniversalProfilesView()
            case .vk: SubscriptionView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Способ подключения", selection: $navigation.route) {
                ForEach(ConnectionRoute.allCases) { route in Text(route.title).tag(route) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 12)
                .background(.regularMaterial)
        }
    }
}
