import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var container: AppContainer
    var body: some View {
        List(container.logStore.entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(entry.level.rawValue).font(.caption.bold()).foregroundStyle(color(entry.level)); Text(entry.source).font(.caption); Spacer(); Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary) }
                Text(entry.message).textSelection(.enabled)
            }.padding(.vertical, 10)
        }
        .overlay {
            if container.logStore.entries.isEmpty {
                BlinkEmptyState(symbol: "text.alignleft", title: "Пока всё спокойно", detail: "Здесь появится история соединений. Если что-то пойдёт не так, она поможет разобраться.").padding(24)
            }
        }
        .navigationTitle("Журнал").blinkScreen()
        .toolbar { Button(action: container.logStore.clear) { Label("Очистить", systemImage: "trash") }.disabled(container.logStore.entries.isEmpty) }
    }
    private func color(_ level: LogEntry.Level) -> Color { switch level { case .info: .blue; case .warning: .orange; case .error: .red } }
}
