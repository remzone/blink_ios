import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var xray: XrayVPNController
    @EnvironmentObject private var navigation: BlinkNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var guidePresented = false
    @State private var vpnProfiles: [UniversalProfile] = []
    @State private var turnDocument: VokopSubscription?
    @State private var turnURL = ""
    @State private var account: SubscriptionAccount?
    @State private var accountUnavailable = false
    @ObservedObject private var statusCenter = PanelStatusCenter.shared
    private var serviceStatus: PanelServiceStatus? { statusCenter.status }
    private var managedMaintenance: Bool { serviceStatus?.maintenance == true && displayedRoute == .vk }
    @State private var seenServiceRevision: Int64 = -1
    @AppStorage("blink.lastVPNProfile") private var vpnID = ""
    @AppStorage("blink.lastTURNProfile") private var turnID = ""
    private let credentialID = UUID(uuidString: "57f8b06a-c211-4b4f-8525-14cb2e7a882e")!
    private let vaultID = UUID(uuidString: "81487391-25f0-41c7-a31c-1454e4c18400")!
    private var selectedVPN: UniversalProfile? { vpnProfiles.first { $0.id.uuidString == vpnID } ?? vpnProfiles.first }
    private var selectedTURN: VokopSubscription.Profile? { turnDocument?.profiles.first { $0.id == turnID } ?? turnDocument?.profiles.first }
    private var selectedName: String { displayedRoute == .direct ? selectedVPN?.name ?? "Добавить VPN-профиль" : selectedTURN?.name ?? "Добавить подписку TURN" }
    private var displayedRoute: ConnectionRoute { xray.hasActiveConnection ? (xray.route ?? .direct) : navigation.route }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    masthead
                    if navigation.route == .direct, let metadata = selectedVPN?.subscriptionMetadata, let expiry = metadata.expiresAt {
                        providerCard(metadata, expiry: expiry)
                    } else if !turnURL.isEmpty { accountCard }
                    if geometry.size.width >= 850 && !typeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 24) { connection; nextSteps }
                    } else { connection; nextSteps }
                    if let error = xray.errorMessage { BlinkNotice(message: error, symbol: "exclamationmark.circle").transition(.opacity) }
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                        Text("Конфигурации хранятся в защищённом хранилище устройства.")
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(geometry.size.width < 360 ? 16 : 22).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.blinkScreen()
        }
        .navigationTitle("Blink").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $guidePresented) { ProtocolGuideView() }
        .onChange(of: statusCenter.status?.revision) { value in
            if seenServiceRevision >= 0, value != seenServiceRevision { Task { await loadLibrary() } }
            seenServiceRevision = value ?? -1
        }
        .animation(reduceMotion ? nil : BlinkTheme.spring, value: xray.hasActiveConnection)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await loadLibrary()
            var refreshTick = 0
            while !Task.isCancelled {
                await xray.refreshTransportStatus()
                refreshTick += 1
                if refreshTick >= 20 { refreshTick = 0; await loadLibrary() }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private var masthead: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Ваша сеть,\nпод вашим контролем.")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-1)
                Text("Выберите маршрут. Остальное — в Blink.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { guidePresented = true } label: {
                Image(systemName: "questionmark").font(.headline).frame(width: 44, height: 44)
                    .background(BlinkTheme.surface, in: Circle())
            }.accessibilityLabel("Как работают обычный VPN и TURN")
        }.padding(.vertical, 8)
    }
    private var connection: some View {
        VStack(spacing: 18) {
            HStack {
                Label("BLINK CONNECT", systemImage: "sparkle").font(.caption2.weight(.bold)).tracking(1.8)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(managedMaintenance ? Color.orange : xray.isConnected ? BlinkTheme.primaryFill : .white.opacity(0.5)).frame(width: 6, height: 6)
                    Text(managedMaintenance ? "Технические работы" : xray.isConnected ? "VPN включён" : xray.isConnecting ? "Подключение" : xray.isDisconnecting ? "Отключение" : "VPN выключен")
                        .font(.caption.weight(.medium))
                }
            }.foregroundStyle(.white.opacity(0.72))
            Button { primaryAction() } label: {
                BlinkOrbit(connected: xray.isConnected && !managedMaintenance, busy: xray.isConnecting && !managedMaintenance, color: managedMaintenance ? Color.orange : displayedRoute == .vk ? Color(red: 0.69, green: 0.72, blue: 1) : BlinkTheme.primaryFill)
                    .frame(maxWidth: 210).frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.plain).disabled(xray.isDisconnecting)
                .accessibilityLabel(primaryTitle)
            Picker("Маршрут", selection: $navigation.route) {
                Label("VPN", systemImage: "shield.lefthalf.filled").tag(ConnectionRoute.direct)
                Label("TURN", systemImage: "arrow.triangle.branch").tag(ConnectionRoute.vk)
            }.pickerStyle(.segmented).disabled(xray.hasActiveConnection)
                .colorScheme(.dark)
            VStack(spacing: 7) {
                Text(managedMaintenance ? "Обновляем сервер" : xray.isConnected ? "Вы на связи" : xray.isConnecting ? "Создаём защищённый маршрут" : "Ваше подключение")
                    .font(.system(.title2, design: .rounded).weight(.bold)).multilineTextAlignment(.center)
                Menu {
                    if displayedRoute == .direct {
                        ForEach(vpnProfiles) { profile in
                            Button { vpnID = profile.id.uuidString } label: {
                                Label(profile.name, systemImage: selectedVPN?.id == profile.id ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    } else if let document = turnDocument {
                        ForEach(document.profiles) { profile in
                            Button { turnID = profile.id } label: {
                                Label("\(profile.name) · \(profile.backendTitle)", systemImage: selectedTURN?.id == profile.id ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    Button { navigation.openLibrary(navigation.route) } label: { Label("Добавить или обновить", systemImage: "plus.circle") }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack")
                        Text(xray.hasActiveConnection ? xray.profileName : selectedName).lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }.font(.subheadline.weight(.medium)).padding(15)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }.disabled(xray.hasActiveConnection)
                Text((displayedRoute == .direct ? vpnID.isEmpty : turnID.isEmpty) ? "По умолчанию · первый доступный сервер" : "Ваш последний выбор")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
            }.foregroundStyle(.white)
            Button { primaryAction() } label: { Label(primaryTitle, systemImage: "power") }
                .buttonStyle(BlinkActionStyle(prominent: true, color: displayedRoute == .vk ? Color(red: 0.72, green: 0.75, blue: 1) : BlinkTheme.primaryFill))
                .disabled(xray.isDisconnecting || (managedMaintenance && !xray.hasActiveConnection))
            Text(xray.hasActiveConnection ? xray.status : selectedName)
                .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).accessibilityLabel("Состояние: \(xray.status)")
        }.padding(24).frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 32, style: .continuous).fill(BlinkTheme.ink)
                    .overlay {
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .fill(RadialGradient(colors: [(displayedRoute == .vk ? BlinkTheme.vk : BlinkTheme.accent).opacity(0.25), .clear], center: .topTrailing, startRadius: 0, endRadius: 380))
                    }
            }
            .overlay { RoundedRectangle(cornerRadius: 32).strokeBorder(.white.opacity(0.08)) }
    }
    private var primaryTitle: String {
        xray.isDisconnecting ? "Отключаем…" : xray.isConnecting ? "Отменить подключение" : xray.isConnected ? "Отключить" : "Подключить"
    }
    private func primaryAction() {
        if managedMaintenance && !xray.hasActiveConnection { return }
        if xray.hasActiveConnection { xray.disconnect() }
        else if navigation.route == .direct, let profile = selectedVPN {
            vpnID = profile.id.uuidString
            Task { await xray.connectUniversal(source: profile.source, name: profile.name, secrets: container.secretStore, diagnosticURL: profile.subscriptionURL) }
        } else if navigation.route == .vk, let profile = selectedTURN, let document = turnDocument {
            turnID = profile.id
            Task { await xray.connect(profile: profile, expiresAt: document.expires_at, secrets: container.secretStore, diagnosticURL: turnURL) }
        } else { navigation.openLibrary(navigation.route) }
    }
    private func providerCard(_ metadata: SubscriptionMetadata, expiry: Int64) -> some View {
        let remaining = max(0, expiry - Int64(Date().timeIntervalSince1970))
        let urgent = remaining <= 259200
        return HStack(spacing: 14) {
            BlinkBadge(symbol: "calendar", color: urgent ? .red : BlinkTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(metadata.title ?? "Подписка провайдера").font(.headline)
                Text(remaining == 0 ? "Срок закончился" : remaining < 86400 ? "Осталось менее суток" : "Осталось \(remaining / 86400) дн.").font(.subheadline.weight(.semibold))
                Text("До \(Date(timeIntervalSince1970: TimeInterval(expiry)).formatted(date: .abbreviated, time: .shortened))").font(.caption)
                Text("По данным последнего обновления подписки").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.foregroundStyle(urgent ? Color.red : Color.primary).blinkCard()
    }
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                BlinkBadge(symbol: account?.urgent == true ? "calendar.badge.exclamationmark" : "checkmark.seal.fill", color: account?.urgent == true ? .red : BlinkTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.map { $0.suspended ? "Доступ приостановлен" : $0.active ? "Подписка оплачена" : "Нужно продлить подписку" } ?? "Статус оплаты")
                        .font(.headline)
                    Text(account?.balance ?? (accountUnavailable ? "Не удалось обновить статус" : "Проверяем оплаченный срок…"))
                        .font(.subheadline)
                }
                Spacer(minLength: 0)
            }
            if let account {
                if account.paid_until > 0 {
                    Text("До \(Date(timeIntervalSince1970: TimeInterval(account.paid_until)).formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline.weight(.semibold))
                }
                HStack {
                    Text("Обновлено \(Date(timeIntervalSince1970: TimeInterval(account.checked_at)).formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let value = account.payment_url, let url = URL(string: value), url.scheme == "https" { Link("Продлить", destination: url).font(.subheadline.weight(.semibold)) }
                }
            }
        }.foregroundStyle(account?.urgent == true ? Color.red : Color.primary)
            .blinkCard().overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(account?.urgent == true ? Color.red.opacity(0.4) : Color.clear) }
    }
    @MainActor private func loadLibrary() async {
        do {
            if let raw = try container.secretStore.read(profileID: vaultID, kind: .universalProfiles) {
                vpnProfiles = try JSONDecoder().decode([UniversalProfile].self, from: Data(raw.utf8))
            }
            if let raw = try container.secretStore.read(profileID: credentialID, kind: .subscriptionURL) {
                let state = try JSONDecoder().decode(SavedVokopSubscription.self, from: Data(raw.utf8))
                turnURL = state.url; turnDocument = state.document
                do {
                    let data = try await VokopSubscriptionClient.fetchControl(try VokopSubscriptionClient.validatedURL(state.url).absoluteString + "/account")
                    let status = try JSONDecoder().decode(SubscriptionAccount.self, from: data)
                    guard status.schema == "vokop.account.v1", status.checked_at > 0, (0...253_402_300_799).contains(status.paid_until) else { throw SubscriptionError.invalidDocument }
                    account = status; accountUnavailable = false
                } catch { accountUnavailable = true; account = nil }
                do {
                    let document = try await VokopSubscriptionClient().fetch(state.url, minimumRevision: state.highestRevision)
                    try Task.checkCancellation()
                    // A delayed refresh must not replace a newly imported subscription.
                    if let raw = try container.secretStore.read(profileID: credentialID, kind: .subscriptionURL) {
                        let current = try JSONDecoder().decode(SavedVokopSubscription.self, from: Data(raw.utf8))
                        guard current.url == state.url, current.highestRevision <= document.revision else { return }
                    } else { return }
                    turnDocument = document
                    let updated = SavedVokopSubscription(url: state.url, highestRevision: document.revision, document: document)
                    try container.secretStore.save(String(decoding: try JSONEncoder().encode(updated), as: UTF8.self), profileID: credentialID, kind: .subscriptionURL)
                } catch SubscriptionError.accessDenied { turnDocument = nil } catch { }
            } else { turnURL = ""; turnDocument = nil; account = nil }
        } catch { accountUnavailable = true }
    }
    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            BlinkSectionHeading(title: "Как подключаться")
            routeCard(.direct, detail: "Ваш сервер и привычные конфигурации. Без TURN и CAPTCHA.")
            routeCard(.vk, detail: "Альтернативный маршрут с подпиской Vokop и проверкой VK.")
            Button { navigation.tab = .diagnostics } label: {
                BlinkDestination(title: "Проверить соединение", subtitle: "Ваш IP и доступ к сервисам", symbol: "waveform.path.ecg")
            }.buttonStyle(.plain).blinkCard()
            Button { guidePresented = true } label: {
                Label("Чем отличаются режимы и конфиги?", systemImage: "info.circle")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }.frame(maxWidth: .infinity)
    }
    private func routeCard(_ route: ConnectionRoute, detail: String) -> some View {
        Button { navigation.openLibrary(route) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    BlinkBadge(symbol: route.symbol, color: route.color)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold)).foregroundStyle(route.color)
                }
                Text(route.title).font(.title3.weight(.bold)).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
        }.buttonStyle(BlinkTileStyle())
    }
}
