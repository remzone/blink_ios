import SwiftUI

/// Scoped Vokop feed; ordinary VPN imports live in UniversalProfilesView.
struct SubscriptionView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var xray: XrayVPNController
    @AppStorage("vokop.turnTransport") private var transport = "tcp"
    @AppStorage("vokop.bootstrapDNS") private var bootstrapDNS = "1.1.1.1"
    @State private var link = ""
    @State private var document: VokopSubscription?
    @State private var message: String?
    @State private var loading = false
    @State private var task: Task<Void, Never>?
    @State private var lastURL = ""
    @State private var highestВерсия: Int64 = 0
    @State private var requestID = UUID()
    private let credentialID = UUID(uuidString: "57f8b06a-c211-4b4f-8525-14cb2e7a882e")!

    var body: some View {
        List {
            Section("Подписка Vokop") {
                Picker("VK TURN", selection: $transport) { Text("TCP").tag("tcp"); Text("UDP").tag("udp") }.disabled(xray.busy)
                TextField("DNS для авторизации VK", text: $bootstrapDNS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Для авторизации VK до запуска VPN используется этот DNS. Укажите IP резолвера.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("HTTPS-ссылка подписки", text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(loading)
                Button(loading ? "Загрузка…" : "Обновить подписку") { refresh() }
                    .disabled(loading || link.isEmpty)
                Button("Забыть подписку", role: .destructive) { forget() }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            if let document {
                Section("Профили подписки") {
                    LabeledContent("Версия", value: String(document.revision))
                    LabeledContent("Действует до", value: Date(timeIntervalSince1970: TimeInterval(document.expires_at)).formatted())
                    ForEach(document.profiles) { profile in
                        VStack(alignment: .leading) {
                            Text(profile.name.isEmpty ? profile.id : profile.name)
                            Button("Подключить через VK TURN") {
                                Task { await xray.connect(profile: profile, expiresAt: document.expires_at, dnsServer: bootstrapDNS, transport: transport, secrets: container.secretStore) }
                            }.disabled(xray.busy)
                            Text("VLESS / VK TURN · \(profile.turn.peer_host):\(profile.turn.peer_port)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Соединение") {
                NavigationLink("Обычные VPN-профили · без VK") { UniversalProfilesView() }
                Text(xray.status)
                if let error = xray.errorMessage { Text(error).foregroundStyle(.red) }
                Button("Проверить состояние") { Task { await xray.refreshTransportStatus() } }
                Button("Отключить", role: .destructive) { xray.disconnect() }
                Text("Выберите профиль подписки и транспорт до VK: TCP или UDP.")
                Text("Экспериментальный VK-транспорт не проверяет сертификат DTLS-сервера. Используйте HTTPS в приложениях.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Обычные ссылки и подписки Xray/WireGuard/AmneziaWG импортируются в разделе VPN-профили.")
            }
            Section("Баланс") {
                Text("Баланс доступен командой /balance в Telegram-боте панели. В клиент вводится только ссылка подписки.")
            }
        }
        .navigationTitle("Vokop").blinkScreen()
        .onAppear {
            guard link.isEmpty else { return }
            do {
                let saved = try container.secretStore.read(profileID: credentialID, kind: .subscriptionURL) ?? ""
                if let state = try? JSONDecoder().decode(SavedVokopSubscription.self, from: Data(saved.utf8)) {
                    link = state.url; lastURL = state.url; highestВерсия = state.highestВерсия
                } else {
                    // One-time compatibility with the earlier URL-only Keychain value.
                    link = saved; lastURL = saved; highestВерсия = 0
                }
            }
            catch { message = "Не удалось прочитать сохранённую подписку." }
        }
        .onDisappear {
            requestID = UUID(); task?.cancel(); task = nil; loading = false
            document = nil; link = ""; lastURL = ""
        }
    }

    private func refresh() {
        task?.cancel()
        let id = UUID(); requestID = id
        let requestedURL = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimumВерсия = requestedURL == lastURL ? highestВерсия : 0
        document = nil; message = nil; loading = true
        task = Task { @MainActor in
            defer { if requestID == id { loading = false } }
            do {
                _ = try VokopSubscriptionClient.validatedURL(requestedURL)
                let result = try await VokopSubscriptionClient().fetch(requestedURL, minimumВерсия: minimumВерсия)
                try Task.checkCancellation()
                guard requestID == id else { return }
                let state = SavedVokopSubscription(url: requestedURL, highestВерсия: result.revision)
                let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
                try container.secretStore.save(encoded, profileID: credentialID, kind: .subscriptionURL)
                document = result; lastURL = requestedURL; link = requestedURL; highestВерсия = result.revision
            } catch is CancellationError {
                // Dismissal/Forget must not repopulate a cleared screen.
            } catch let error as SubscriptionError {
                if requestID == id { message = error.localizedDescription }
            } catch {
                if requestID == id { message = "Не удалось сохранить подписку." }
            }
        }
    }

    private func forget() {
        requestID = UUID(); task?.cancel(); task = nil
        document = nil; lastURL = ""; highestВерсия = 0; link = ""; loading = false
        do {
            try container.secretStore.delete(profileID: credentialID)
            message = "Подписка удалена."
        } catch { message = "Не удалось удалить подписку." }
    }
}
