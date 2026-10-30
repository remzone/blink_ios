import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { ProfilesView() }
                .tabItem { Label("Profiles", systemImage: "list.bullet.rectangle") }
            NavigationStack { SubscriptionView() }
                .tabItem { Label("Vokop", systemImage: "person.crop.circle") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.blue)
    }
}
