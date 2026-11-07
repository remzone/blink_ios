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

    @State private var advanced = false
    @State private var guidePresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    private var columns: [GridItem] { textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 280), spacing: 16)] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlinkHeader(title: "Другой путь к сети", subtitle: "Ваши серверы с маршрутом через VK.")
                RouteExplainer(route: .vk)
                subscriptionCard
                if let message { BlinkNotice(message: message).transition(.opacity) }
                if xray.hasActiveConnection || xray.errorMessage != nil { ActiveConnectionCard() }
                if xray.route == .vk && xray.hasActiveConnection { VKJourneyView() }
                if let document {
                    subscriptionSummary(document)
                    BlinkSectionHeading(title: "Серверы через VK", detail: "\(document.profiles.count)")
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(document.profiles) { profile in vkProfileCard(profile, document: document) }
                    }
                } else if !loading {
                    BlinkEmptyState(symbol: "arrow.triangle.branch", title: "Здесь будет ваш маршрут через VK", detail: "Добавьте подписку Vokop и загрузите серверы. Обычные VPN-ссылки добавляются в соседнем режиме.").blinkCard()
                }
                DisclosureGroup("О подключении через VK") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("VK может попросить CAPTCHA перед запуском VPN. Вход в ваше приложение VK не используется.")
                        Text("Баланс подписки доступен по команде /balance в Telegram-боте провайдера.")
                        Text("В экспериментальном VK-транспорте сертификат DTLS-сервера не проверяется. Для защиты содержимого используйте HTTPS в приложениях.")
                    }.font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                }.font(.subheadline.weight(.medium)).blinkCard()
                Button { guidePresented = true } label: { Label("Чем VK отличается от обычного VPN?", systemImage: "questionmark.circle").font(.subheadline) }
            }.padding(20).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }
        .navigationTitle("Библиотека").navigationBarTitleDisplayMode(.inline).blinkScreen().tint(BlinkTheme.vk)
        .sheet(isPresented: $guidePresented) { ProtocolGuideView() }
        .animation(reduceMotion ? nil : BlinkTheme.spring, value: loading)
        .animation(reduceMotion ? nil : BlinkTheme.spring, value: xray.authorizationPhase)
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

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                BlinkBadge(symbol: "rectangle.stack.fill", color: BlinkTheme.vk)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Подписка Vokop").font(.headline)
                    Text(lastURL.isEmpty ? "Добавьте ссылку от провайдера" : "Ссылка сохранена на устройстве").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !lastURL.isEmpty {
                    Menu {
                        Button(role: .destructive) { confirmForget = true } label: { Label("Удалить подписку", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }.accessibilityLabel("Действия с подпиской")
                }
            }
            SecureField("HTTPS-ссылка Vokop", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(14).background(BlinkTheme.background, in: RoundedRectangle(cornerRadius: 14)).disabled(loading)
            PasteButton(payloadType: String.self) { if let value = $0.first { link = value.trimmingCharacters(in: .whitespacesAndNewlines) } }.disabled(loading)
            Button { refresh() } label: { Label(loading ? "Загружаем серверы…" : document == nil ? "Загрузить серверы" : "Обновить серверы", systemImage: "arrow.clockwise") }
                .buttonStyle(BlinkActionStyle(prominent: true, color: Color(red: 0.75, green: 0.78, blue: 1))).disabled(loading || link.isEmpty)
            if loading { ProgressView().frame(maxWidth: .infinity) }
            DisclosureGroup("Параметры подключения", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Транспорт до VK").font(.caption).foregroundStyle(.secondary)
                    Picker("Транспорт до VK", selection: $transport) { Text("TCP").tag("tcp"); Text("UDP").tag("udp") }.pickerStyle(.segmented)
                    Text("Оставьте TCP, если провайдер не рекомендовал другое значение.").font(.caption).foregroundStyle(.secondary)
                    TextField("DNS для авторизации VK", text: $bootstrapDNS).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(12).background(BlinkTheme.background, in: RoundedRectangle(cornerRadius: 12))
                    Text("Этот DNS используется до подключения VPN. Нужен IP-адрес резолвера.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 14).disabled(xray.hasActiveConnection)
            }.font(.subheadline)
        }.blinkCard()
    }
    private func subscriptionSummary(_ document: VokopSubscription) -> some View {
        HStack(alignment: .top, spacing: 14) {
            BlinkBadge(symbol: "calendar", color: BlinkTheme.vk)
            VStack(alignment: .leading, spacing: 5) {
                Text("Подписка действует до").font(.caption).foregroundStyle(.secondary)
                Text(Date(timeIntervalSince1970: TimeInterval(document.expires_at)).formatted(date: .abbreviated, time: .omitted)).font(.headline)
                Text("Ревизия \(document.revision) · \(document.profiles.count) серверов").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.blinkCard()
    }
    private func vkProfileCard(_ profile: VokopSubscription.Profile, document: VokopSubscription) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                BlinkBadge(symbol: "server.rack", color: BlinkTheme.vk)
                Text(profile.name.isEmpty ? profile.id : profile.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack { BlinkPill(title: "Через VK", symbol: "arrow.triangle.branch", color: BlinkTheme.vk); BlinkPill(title: "VLESS", color: BlinkTheme.vk) }
                VStack(alignment: .leading) { BlinkPill(title: "Через VK", symbol: "arrow.triangle.branch", color: BlinkTheme.vk); BlinkPill(title: "VLESS", color: BlinkTheme.vk) }
            }
            Text("Авторизация VK → VK TURN → VPN-сервер").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { Task { await xray.connect(profile: profile, expiresAt: document.expires_at, dnsServer: bootstrapDNS, transport: transport, secrets: container.secretStore) } } label: {
                Label("Подключить через VK", systemImage: "power")
            }.buttonStyle(BlinkActionStyle(prominent: true, color: Color(red: 0.75, green: 0.78, blue: 1))).disabled(xray.hasActiveConnection)
        }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
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
            } catch let error as NetworkRequestError {
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
