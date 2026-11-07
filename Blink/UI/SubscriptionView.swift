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
    @State private var highestRevision: Int64 = 0
    @State private var requestID = UUID()
    private let credentialID = UUID(uuidString: "57f8b06a-c211-4b4f-8525-14cb2e7a882e")!

    @State private var confirmForget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlinkHeader(title: "Связь другим путём.", subtitle: "Твоя подписка Vokop и подключение через VK.")
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) { BlinkBadge(symbol: "arrow.triangle.branch"); Text("Подписка Vokop").font(.title3.weight(.semibold)) }
                    SecureField("HTTPS-ссылка подписки", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).disabled(loading)
                    Text("Транспорт до VK").font(.caption).foregroundStyle(.secondary)
                    Picker("VK TURN", selection: $transport) { Text("TCP").tag("tcp"); Text("UDP").tag("udp") }.pickerStyle(.segmented).disabled(xray.busy)
                    TextField("DNS для авторизации VK", text: $bootstrapDNS).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    Text("Этот DNS используется до подключения VPN. Укажи IP резолвера.").font(.caption).foregroundStyle(.secondary)
                    Button { refresh() } label: { Label(loading ? "Загружаем…" : "Обновить подписку", systemImage: "arrow.clockwise") }.buttonStyle(BlinkActionStyle(prominent: true)).disabled(loading || link.isEmpty)
                    Button(role: .destructive) { confirmForget = true } label: { Label("Забыть подписку", systemImage: "trash").font(.callout) }
                    if loading { ProgressView("Получаем твои серверы…") }
                }.blinkCard()
                if let message { BlinkNotice(message: message) }
                if let document {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Всё под рукой", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                        LabeledContent("Действует до", value: Date(timeIntervalSince1970: TimeInterval(document.expires_at)).formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("Серверы", value: String(document.profiles.count))
                        LabeledContent("Версия подписки", value: String(document.revision))
                    }.blinkCard()
                    LazyVStack(spacing: 16) {
                        ForEach(document.profiles) { profile in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 14) { BlinkBadge(symbol: "globe.europe.africa"); Text(profile.name.isEmpty ? profile.id : profile.name).font(.headline).fixedSize(horizontal: false, vertical: true) }
                                Button { Task { await xray.connect(profile: profile, expiresAt: document.expires_at, dnsServer: bootstrapDNS, transport: transport, secrets: container.secretStore) } } label: { Label("Подключить через VK", systemImage: "power") }.buttonStyle(BlinkActionStyle(prominent: true)).disabled(xray.busy)
                                Text("VLESS / VK TURN · \(profile.turn.peer_host):\(profile.turn.peer_port)").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
                        }
                    }
                } else {
                    BlinkEmptyState(symbol: "arrow.triangle.branch", title: "Добавь свой маршрут", detail: "Вставь ссылку подписки Vokop и обнови список. Здесь появятся доступные серверы.").blinkCard()
                }
                VStack(alignment: .leading, spacing: 16) {
                    Label("Соединение", systemImage: "waveform.path.ecg").font(.headline)
                    Text(xray.status).font(.subheadline).foregroundStyle(.secondary)
                    if let error = xray.errorMessage { BlinkNotice(message: error, symbol: "exclamationmark.circle") }
                    Button { Task { await xray.refreshTransportStatus() } } label: { Label("Проверить состояние", systemImage: "arrow.clockwise") }.buttonStyle(BlinkActionStyle())
                    Button { xray.disconnect() } label: { Label("Отключить туннель", systemImage: "power") }.buttonStyle(BlinkActionStyle()).disabled(!xray.isConnected && !xray.busy)
                    NavigationLink { UniversalProfilesView() } label: { Label("Обычные VPN-профили", systemImage: "globe.europe.africa") }
                }.blinkCard()
                BlinkNotice(message: "VK может попросить ручную проверку. В экспериментальном VK-транспорте сертификат DTLS-сервера не проверяется — используй HTTPS в приложениях.", symbol: "shield.lefthalf.filled")
                BlinkNotice(message: "Баланс доступен по команде /balance в Telegram-боте панели. Здесь достаточно ссылки подписки.", symbol: "creditcard")
            }.padding(22).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }.navigationTitle("Через VK").navigationBarTitleDisplayMode(.inline).blinkScreen()
        .confirmationDialog("Забыть подписку Vokop?", isPresented: $confirmForget, titleVisibility: .visible) { Button("Забыть подписку", role: .destructive) { forget() }; Button("Оставить", role: .cancel) {} }
        .onAppear {
            guard link.isEmpty else { return }
            do {
                let saved = try container.secretStore.read(profileID: credentialID, kind: .subscriptionURL) ?? ""
                if let state = try? JSONDecoder().decode(SavedVokopSubscription.self, from: Data(saved.utf8)) {
                    link = state.url; lastURL = state.url; highestRevision = state.highestRevision
                } else {
                    // One-time compatibility with the earlier URL-only Keychain value.
                    link = saved; lastURL = saved; highestRevision = 0
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
        let minimumRevision = requestedURL == lastURL ? highestRevision : 0
        document = nil; message = nil; loading = true
        task = Task { @MainActor in
            defer { if requestID == id { loading = false } }
            do {
                _ = try VokopSubscriptionClient.validatedURL(requestedURL)
                let result = try await VokopSubscriptionClient().fetch(requestedURL, minimumRevision: minimumRevision)
                try Task.checkCancellation()
                guard requestID == id else { return }
                let state = SavedVokopSubscription(url: requestedURL, highestRevision: result.revision)
                let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
                try container.secretStore.save(encoded, profileID: credentialID, kind: .subscriptionURL)
                document = result; lastURL = requestedURL; link = requestedURL; highestRevision = result.revision
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
        document = nil; lastURL = ""; highestRevision = 0; link = ""; loading = false
        do {
            try container.secretStore.delete(profileID: credentialID)
            message = "Подписка удалена."
        } catch { message = "Не удалось удалить подписку." }
    }
}
