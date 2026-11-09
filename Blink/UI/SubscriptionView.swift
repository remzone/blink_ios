import SwiftUI

/// Scoped Vokop feed; ordinary VPN imports live in UniversalProfilesView.
struct SubscriptionView: View {
    @EnvironmentObject private var navigation: BlinkNavigation
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var xray: XrayVPNController
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

    @State private var guidePresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    private var columns: [GridItem] { textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 280), spacing: 16)] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlinkHeader(title: "Другой путь к сети", subtitle: "Ваши серверы с маршрутом через TURN.")
                RouteExplainer(route: .vk)
                subscriptionCard
                if let message { BlinkNotice(message: message).transition(.opacity) }
                if xray.hasActiveConnection || xray.errorMessage != nil { ActiveConnectionCard() }
                if xray.route == .vk && xray.hasActiveConnection { VKJourneyView() }
                if let document {
                    subscriptionSummary(document)
                    BlinkSectionHeading(title: "Серверы через TURN", detail: "\(document.profiles.count)")
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(document.profiles) { profile in vkProfileCard(profile, document: document) }
                    }
                } else if !loading {
                    BlinkEmptyState(symbol: "arrow.triangle.branch", title: "Здесь будет ваш маршрут через TURN", detail: "Добавьте подписку Vokop и загрузите серверы. Обычные VPN-ссылки добавляются в соседнем режиме.").blinkCard()
                }
                DisclosureGroup("О подключении через TURN") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("VK может попросить CAPTCHA перед запуском VPN. Вход в ваше приложение VK не используется.")
                        Text("Оплаченный срок и дата окончания доступны на главном экране.")
                        Text("В экспериментальном TURN-транспорте сертификат DTLS-сервера не проверяется. Для защиты содержимого используйте HTTPS в приложениях.")
                    }.font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                }.font(.subheadline.weight(.medium)).blinkCard()
                Button { guidePresented = true } label: { Label("Чем TURN отличается от обычного VPN?", systemImage: "questionmark.circle").font(.subheadline) }
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
                    link = state.url; lastURL = state.url; highestRevision = state.highestRevision; document = state.document
                } else {
                    // One-time compatibility with the earlier URL-only Keychain value.
                    link = saved; lastURL = saved; highestRevision = 0
                }
            }
            catch { message = "Не удалось прочитать сохранённую подписку." }
            if let pending = navigation.pendingTURNURL { link = pending; navigation.pendingTURNURL = nil; refresh() }
            else if !link.isEmpty { refresh() }
        }
        .onDisappear {
            requestID = UUID(); task?.cancel(); task = nil; loading = false
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
            Label("Параметры подключения управляются вашей подпиской", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)

        }.blinkCard()
    }
    private func subscriptionSummary(_ document: VokopSubscription) -> some View {
        HStack(alignment: .top, spacing: 14) {
            BlinkBadge(symbol: "calendar", color: document.expires_at - Int64(Date().timeIntervalSince1970) <= 259200 ? .red : BlinkTheme.vk)
            VStack(alignment: .leading, spacing: 5) {
                Text("Конфигурации действуют до").font(.caption).foregroundStyle(.secondary)
                Text(Date(timeIntervalSince1970: TimeInterval(document.expires_at)).formatted(date: .abbreviated, time: .omitted)).font(.headline)
                Text("Оплаченный срок — на главном экране · \(document.profiles.count) серверов").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.blinkCard()
    }
    private func vkProfileCard(_ profile: VokopSubscription.Profile, document: VokopSubscription) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProfileEmojiBadge(presentation: ProfilePresentation(name: profile.name), fallback: "server.rack", color: BlinkTheme.vk)
                Text(ProfilePresentation(name: profile.name.isEmpty ? profile.id : profile.name).title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack { BlinkPill(title: "Через TURN", symbol: "arrow.triangle.branch", color: BlinkTheme.vk); BlinkPill(title: profile.backendTitle, color: BlinkTheme.vk) }
                VStack(alignment: .leading) { BlinkPill(title: "Через TURN", symbol: "arrow.triangle.branch", color: BlinkTheme.vk); BlinkPill(title: profile.backendTitle, color: BlinkTheme.vk) }
            }
            if let country = ProfilePresentation(name: profile.name).country { Label(country, systemImage: "globe.europe.africa").font(.caption).foregroundStyle(.secondary) }
            Text("Авторизация VK → TURN → VPN-сервер").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { Task { UserDefaults.standard.set(profile.id, forKey: "blink.lastTURNProfile"); await xray.connect(profile: profile, expiresAt: document.expires_at, secrets: container.secretStore, diagnosticURL: lastURL) } } label: {
                Label("Подключить через TURN", systemImage: "power")
            }.buttonStyle(BlinkActionStyle(prominent: true, color: Color(red: 0.75, green: 0.78, blue: 1))).disabled(xray.hasActiveConnection)
        }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
    }

    private func refresh() {
        task?.cancel()
        let id = UUID(); requestID = id
        let requestedURL: String
        do {
            guard case .subscription(let value) = try ProfileImportInput.parse(link) else { throw SubscriptionError.invalidURL }
            requestedURL = try VokopSubscriptionClient.validatedURL(value).absoluteString
        } catch { message = "Вставьте HTTPS-ссылку подписки TURN."; return }
        let minimumRevision = requestedURL == lastURL ? highestRevision : 0
        document = nil; message = nil; loading = true
        task = Task { @MainActor in
            defer { if requestID == id { loading = false } }
            do {
                _ = try VokopSubscriptionClient.validatedURL(requestedURL)
                let result = try await VokopSubscriptionClient().fetch(requestedURL, minimumRevision: minimumRevision)
                try Task.checkCancellation()
                guard requestID == id else { return }
                let state = SavedVokopSubscription(url: requestedURL, highestRevision: result.revision, document: result)
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
