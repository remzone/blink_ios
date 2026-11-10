import SwiftUI

struct ProfileEmojiBadge: View {
    let presentation: ProfilePresentation
    let fallback: String
    var color: Color = BlinkTheme.accent
    var body: some View {
        Group {
            if let emoji = presentation.emoji {
                Text(emoji).font(.system(size: 29)).frame(width: 46, height: 46)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            } else { BlinkBadge(symbol: fallback, color: color) }
        }.accessibilityHidden(true)
    }
}
struct SubscriptionMetadataSummary: View {
    let metadata: SubscriptionMetadata?
    var body: some View {
        if let metadata {
            VStack(alignment: .leading, spacing: 7) {
                if let summary = metadata.trafficSummary { Label(summary, systemImage: "arrow.up.arrow.down").font(.caption).foregroundStyle(.secondary) }
                if let fraction = metadata.fractionUsed { ProgressView(value: fraction).tint(BlinkTheme.accent) }
                if let expiry = metadata.expiresAt {
                    Label("До \(Date(timeIntervalSince1970: TimeInterval(expiry)).formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                }
                if let updatedAt = metadata.updatedAt { Label("Обновлено " + updatedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary) }
                if let announcement = metadata.announcement { Text(announcement).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}
