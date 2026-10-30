import Foundation
import Combine

struct LogEntry: Identifiable {
    enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR" }
    let id = UUID(); let date = Date(); let level: Level; let source: String; let message: String
}

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    func add(_ level: LogEntry.Level, source: String, message: String) {
        entries.insert(LogEntry(level: level, source: source, message: message), at: 0)
        entries = Array(entries.prefix(500))
    }
    func clear() { entries.removeAll() }
}
