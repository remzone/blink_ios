import SwiftUI
import Combine

enum BlinkTab: String, CaseIterable, Identifiable {
    case home, library, diagnostics, settings
    var id: Self { self }
    var title: String {
        switch self { case .home: return "Подключение"; case .library: return "Библиотека"; case .diagnostics: return "Проверка"; case .settings: return "Настройки" }
    }
    var symbol: String {
        switch self { case .home: return "power.circle.fill"; case .library: return "square.stack.3d.up.fill"; case .diagnostics: return "waveform.path.ecg"; case .settings: return "gearshape.fill" }
    }
}
@MainActor
final class BlinkNavigation: ObservableObject {
    @Published var tab: BlinkTab = .home
    @Published var route: ConnectionRoute = .direct
    func openLibrary(_ route: ConnectionRoute) { self.route = route; tab = .library }
}

extension ConnectionRoute {
    var color: Color { self == .direct ? BlinkTheme.accent : BlinkTheme.vk }
}
