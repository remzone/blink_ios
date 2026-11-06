import SwiftUI
import UIKit

/// Shared design tokens. System typography keeps every screen scalable.
enum BlinkTheme {
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.36, green: 0.83, blue: 0.71, alpha: 1) : UIColor(red: 0, green: 0.43, blue: 0.36, alpha: 1) })
    static let primaryFill = Color(red: 0.58, green: 0.91, blue: 0.82)
    static let ice = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.61, green: 0.75, blue: 1, alpha: 1) : UIColor(red: 0.18, green: 0.36, blue: 0.64, alpha: 1) })
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1) : UIColor(red: 0.94, green: 0.96, blue: 0.98, alpha: 1) })
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let stroke = Color.primary.opacity(0.08)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
}
struct BlinkBackdrop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            BlinkTheme.background
            RadialGradient(colors: [BlinkTheme.ice.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 650)
            RadialGradient(colors: [BlinkTheme.accent.opacity(0.08), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 500)
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}
struct BlinkScreenStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background { BlinkBackdrop() }.tint(BlinkTheme.accent)
    }
}
extension View {
    func blinkScreen() -> some View { modifier(BlinkScreenStyle()) }
    func blinkCard() -> some View { padding(22).background(BlinkTheme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 26, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(BlinkTheme.stroke) } }
}
struct BlinkActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).padding(18)
            .foregroundStyle(prominent ? Color(red: 0.025, green: 0.09, blue: 0.10) : Color.primary)
            .background(prominent ? BlinkTheme.primaryFill : BlinkTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(prominent ? .clear : BlinkTheme.stroke) }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(enabled ? configuration.isPressed ? 0.8 : 1 : 0.45)
            .animation(reduceMotion ? nil : BlinkTheme.spring, value: configuration.isPressed)
    }
}
struct BlinkBadge: View {
    let symbol: String
    var color: Color = BlinkTheme.accent
    var body: some View { Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(color).frame(width: 46, height: 46).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous)).accessibilityHidden(true) }
}
struct BlinkHeader: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 10) { Label("B L I N K", systemImage: "shield.lefthalf.filled").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(BlinkTheme.accent); Text(title).font(.largeTitle.weight(.semibold)).tracking(-0.8).fixedSize(horizontal: false, vertical: true); Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12) }
}
struct BlinkEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View { VStack(spacing: 16) { BlinkBadge(symbol: symbol); Text(title).font(.title3.weight(.semibold)); Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 26).accessibilityElement(children: .combine) }
}
struct BlinkNotice: View {
    let message: String
    var symbol = "info.circle"
    var body: some View { Label { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(BlinkTheme.accent) }.foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(BlinkTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18)) }
}
struct BlinkDestination: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 16) { BlinkBadge(symbol: symbol); VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }; Spacer(minLength: 4); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct BlinkOrbit: View {
    let connected: Bool
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var rotating = false
    private var animating: Bool { busy && !reduceMotion && phase == .active }
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [BlinkTheme.accent.opacity(connected ? 0.24 : 0.10), .clear], center: .center, startRadius: 10, endRadius: 120))
            Circle().strokeBorder(BlinkTheme.ice.opacity(0.12), lineWidth: 1).padding(6)
            Circle().strokeBorder(BlinkTheme.ice.opacity(0.2), lineWidth: 1).padding(20)
            Circle().trim(from: 0.05, to: busy ? 0.3 : 0.82).stroke(AngularGradient(colors: [BlinkTheme.ice.opacity(0.15), BlinkTheme.ice, BlinkTheme.accent], center: .center), style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).padding(20).rotationEffect(.degrees(rotating ? 360 : 0))
                .animation(animating ? .linear(duration: 2.8).repeatForever(autoreverses: false) : nil, value: rotating)
            Circle().fill(.ultraThinMaterial).overlay { Circle().strokeBorder(BlinkTheme.stroke) }.padding(43)
            Image(systemName: connected ? "checkmark.shield" : "power").font(.system(size: 42, weight: .light)).foregroundStyle(connected ? BlinkTheme.accent : BlinkTheme.ice)
        }.aspectRatio(1, contentMode: .fit).frame(maxWidth: 210).accessibilityHidden(true)
            .onAppear { rotating = animating }
            .onChange(of: animating) { rotating = $0 }
            .onDisappear { rotating = false }
    }
}
