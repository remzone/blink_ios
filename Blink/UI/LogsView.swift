import SwiftUI

struct LogsView: View {
    @ObservedObject private var diagnostics = DiagnosticCenter.shared
    @State private var link = ""
    @State private var message: String?
    @State private var sending = false
    var body: some View {
        List {
            Section("Доставка на сервер") {
                LabeledContent("Сессия") { Text(diagnostics.sessionID).font(.caption.monospaced()).textSelection(.enabled) }
                LabeledContent("Ожидают отправки", value: String(diagnostics.pendingCount))
                if diagnostics.lastHTTPStatus != 0 {
                    Text(diagnostics.lastHTTPStatus == 200 ? "Сервер подтвердил приём" : diagnostics.lastHTTPStatus == -1 ? "Сервер пока недоступен. Записи сохранены на устройстве." : "Сервер ответил HTTP \(diagnostics.lastHTTPStatus). Записи остаются в очереди.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { sending = true; Task { await diagnostics.flushNow(); sending = false } } label: {
                    HStack { if sending { ProgressView() }; Label("Отправить накопленные записи", systemImage: "arrow.up.doc") }
                }.disabled(sending)
            }
            Section {
                SecureField("HTTPS-ссылка диагностики из панели", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                PasteButton(payloadType: String.self) { if let value = $0.first { link = value } }
                Button("Подключить сервер диагностики") {
                    do { try diagnostics.configure(link.trimmingCharacters(in: .whitespacesAndNewlines)); link = ""; message = "Сервер сохранён. Очередь отправится при доступной сети." }
                    catch { message = "Нужна диагностическая ссылка из Vokop-панели, вкладка «Диагностика iOS»." }
                }.disabled(link.isEmpty)
                if let message { Text(message).font(.caption) }
            } header: { Text("Для отдельных конфигураций") } footer: {
                Text("Для подписок Blink пытается использовать сервер подписки автоматически. Для отдельного конфига получите в панели отдельную ссылку диагностики. Ключи VPN, токены и содержимое трафика не записываются.")
            }
            Section("События приложения и туннеля") {
                if diagnostics.events.isEmpty { Text("Ожидаем события…").foregroundStyle(.secondary) }
                ForEach(diagnostics.events) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(entry.source).font(.caption.bold()); Spacer(); Text(Date(timeIntervalSince1970: Double(entry.occurredAt) / 1000), style: .time).font(.caption).foregroundStyle(.secondary) }
                        Text(entry.event).font(.subheadline.monospaced()).textSelection(.enabled)
                        if !entry.fields.isEmpty { Text(entry.fields.keys.sorted().map { "\($0)=\(entry.fields[$0] ?? 0)" }.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(.vertical, 5)
                }
            }
        }.navigationTitle("Диагностика и журналы").navigationBarTitleDisplayMode(.inline).blinkScreen()
            .task { await diagnostics.flushNow() }
            .onDisappear { link = "" }
    }
}
