import SwiftUI

@main
struct BlinkApp: App {
    @StateObject private var container = AppContainer()

    @StateObject private var xray = XrayVPNController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .task { DiagnosticCenter.shared.start() }
                .environmentObject(container)
                .environmentObject(xray)
                .environmentObject(xray.authorization)

        }
    }
}
