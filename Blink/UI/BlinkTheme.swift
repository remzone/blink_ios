import SwiftUI
import UIKit

enum BlinkTheme {
    static let accent = Color(red: 0.17, green: 0.72, blue: 0.61)
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.05, green: 0.08, blue: 0.13, alpha: 1) : UIColor(red: 0.94, green: 0.96, blue: 0.98, alpha: 1) })
}
struct BlinkScreenStyle: ViewModifier {
    func body(content: Content) -> some View { content.scrollContentBackground(.hidden).background(BlinkTheme.background.ignoresSafeArea()).tint(BlinkTheme.accent) }
}
extension View { func blinkScreen() -> some View { modifier(BlinkScreenStyle()) } }
struct BlinkActionStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? BlinkTheme.accent : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
