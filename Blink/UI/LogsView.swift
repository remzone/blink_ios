import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var container: AppContainer
    var body: some View {
        List(container.logStore.entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(entry.level.rawValue).font(.caption.bold()).foregroundStyle(color(entry.level)); Text(entry.source).font(.caption); Spacer(); Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary) }
                Text(entry.message).textSelection(.enabled)
            }.padding(.vertical, 4)
        }
        .overlay {
            if container.logStore.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No logs").font(.headline)
                }
            }
        }
        .navigationTitle("Logs")
        .toolbar { Button("Clear", action: container.logStore.clear) }
    }
    private func color(_ level: LogEntry.Level) -> Color { switch level { case .info: .blue; case .warning: .orange; case .error: .red } }
}
