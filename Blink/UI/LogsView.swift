import SwiftUI

struct LogsView: View {
    @ObservedObject private var diagnostics = DiagnosticCenter.shared
    @State private var link = ""
    @State private var message: String?
    @State private var sending = false
    @State private var confirmReset = false
    @EnvironmentObject private var xray: XrayVPNController
    var body: some View {
        List {
            Section("Доставка на сервер") {
                Text("Записи хранятся на устройстве. Передача выполняется только по кнопке, без фоновых отправок.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Сессия") { Text(diagnostics.sessionID).font(.caption.monospaced()).textSelection(.enabled) }
                LabeledContent("Ожидают отправки", value: String(diagnostics.pendingCount))
                if diagnostics.lastHTTPStatus != 0 {
                    Text(diagnostics.lastHTTPStatus == 200 ? "Сервер подтвердил приём" : diagnostics.lastHTTPStatus == 403 ? "Панель отклонила приём. Записи остаются на устройстве." : diagnostics.lastHTTPStatus == 429 ? "Достигнут серверный лимит диагностики." : diagnostics.lastHTTPStatus == -1 ? "Сервер пока недоступен. Записи сохранены на устройстве." : "Сервер ответил HTTP \(diagnostics.lastHTTPStatus). Записи остаются в очереди.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { sending = true; Task { await diagnostics.flushNow(); sending = false } } label: {
                    HStack { if sending { ProgressView() }; Label("Отправить накопленные записи", systemImage: "arrow.up.doc") }
                }.disabled(sending || diagnostics.sending)
            }
            Section {
                SecureField("HTTPS-ссылка диагностики из панели", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                PasteButton(payloadType: String.self) { if let value = $0.first { link = value } }
                Button("Подключить сервер диагностики") {
                    do { try diagnostics.configure(link.trimmingCharacters(in: .whitespacesAndNewlines)); link = ""; message = "Сервер сохранён. Для отправки нажмите кнопку выше." }
                    catch { message = "Нужна диагностическая ссылка из Vokop-панели, вкладка «Диагностика»." }
                }.disabled(link.isEmpty || diagnostics.sending)
                if let message { Text(message).font(.caption) }
            } header: { Text("Для отдельных конфигураций") } footer: {
                Text("Для подписок Blink определяет адрес сервера диагностики из ссылки, но отправляет записи только по кнопке. Для отдельного конфига получите в панели отдельную ссылку диагностики. Ключи VPN, токены и содержимое трафика не записываются.")
            }
            Section {
                Button("Сбросить локальный журнал", role: .destructive) { confirmReset = true }.disabled(sending || diagnostics.sending || xray.hasActiveConnection)
                Text("Удаляются записи и очередь отправки с этого устройства. Серверные копии управляются в панели. Для сброса отключите VPN; адрес сервера диагностики сохранится.").font(.caption).foregroundStyle(.secondary)
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
        }.confirmationDialog("Удалить локальные диагностические записи?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Удалить журнал", role: .destructive) { guard !sending, !diagnostics.sending, !xray.hasActiveConnection else { return }; diagnostics.resetLocal() }
            Button("Отмена", role: .cancel) {}
        }.navigationTitle("Диагностика и журналы").navigationBarTitleDisplayMode(.inline).blinkScreen()
            .task { await diagnostics.flushNow() }
            .onDisappear { link = "" }
    }
}
