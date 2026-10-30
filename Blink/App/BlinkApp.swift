import SwiftUI

@main
struct BlinkApp: App {
    @StateObject private var container = AppContainer()

    @StateObject private var xray = XrayVPNController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(xray)
                .preferredColorScheme(.dark)
        }
    }
}
