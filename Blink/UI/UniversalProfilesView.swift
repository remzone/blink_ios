import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct UniversalProfilesView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var xray: XrayVPNController
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var profiles: [UniversalProfile] = []
    @State private var input = ""
    @State private var search = ""
    @State private var filter = 0
    @State private var pendingDelete: UniversalProfile?
    @State private var deletePresented = false
    @State private var details: UniversalProfile?
    @State private var importPresented = false
    @State private var guidePresented = false
    @State private var message: String?
    @State private var importing = false
    @State private var filePresented = false
    @State private var scannerPresented = false
    @State private var scannedText: String?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var readingPhoto = false
    @State private var photoID = UUID()
    @State private var photoTask: Task<Void, Never>?
    @State private var importID = UUID()
    @State private var importTask: Task<Void, Never>?
    private let vaultID = UUID(uuidString: "81487391-25f0-41c7-a31c-1454e4c18400")!
    private var columns: [GridItem] { textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 290), spacing: 16)] }
    private var filtered: [UniversalProfile] {
        profiles.filter { profile in
            let matchesSource = filter == 0 || (filter == 1 ? profile.subscriptionURL != nil : profile.subscriptionURL == nil)
            let info = VPNProtocolInfo.describe(kind: profile.kind, source: profile.source)
            return matchesSource && (search.isEmpty || (profile.name + " " + info.title).localizedCaseInsensitiveContains(search))
        }
    }
    private var subscriptions: [String] { Array(Set(profiles.compactMap(\.subscriptionURL))).sorted() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlinkHeader(title: "Ваши подключения", subtitle: "Серверы и подписки, которые всегда под рукой.")
                RouteExplainer(route: .direct)
                importHub
                if importing || readingPhoto { ProgressView(importing ? "Добавляем конфигурацию…" : "Читаем QR-код…").frame(maxWidth: .infinity).padding() }
                if let message { BlinkNotice(message: message).transition(.opacity) }
                if xray.hasActiveConnection || xray.errorMessage != nil { ActiveConnectionCard() }
                if !profiles.isEmpty {
                    BlinkSectionHeading(title: "Мои серверы", detail: "\(profiles.count)")
                    Picker("Источник конфигурации", selection: $filter) {
                        Text("Все").tag(0); Text("Из подписок").tag(1); Text("Отдельные").tag(2)
                    }.pickerStyle(.segmented)
                }
                if profiles.isEmpty {
                    BlinkEmptyState(symbol: "square.stack.3d.up", title: "Первый сервер — с одной ссылки", detail: "Добавьте конфигурацию провайдера или отсканируйте QR. Здесь появятся ваши подключения.").blinkCard()
                } else if filtered.isEmpty {
                    BlinkEmptyState(symbol: "magnifyingglass", title: "Ничего не найдено", detail: "Попробуйте другое название или выберите все источники.").blinkCard()
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filtered) { profile in profileCard(profile) }
                }
                if !subscriptions.isEmpty {
                    BlinkSectionHeading(title: "Подписки", detail: "\(subscriptions.count)")
                    VStack(spacing: 0) {
                        ForEach(subscriptions, id: \.self) { url in
                            Button { importText(url) } label: {
                                HStack(spacing: 12) {
                                    BlinkBadge(symbol: "rectangle.stack")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(URLComponents(string: url)?.host ?? "Провайдер").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text("Обновить список серверов").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.clockwise").foregroundStyle(BlinkTheme.accent)
                                }.padding(.vertical, 10)
                            }.buttonStyle(.plain).disabled(importing || readingPhoto)
                        }
                    }.blinkCard()
                }
                Button { guidePresented = true } label: { Label("Как разобраться в конфигурациях", systemImage: "questionmark.circle").font(.subheadline) }
            }.padding(20).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }
        .navigationTitle("Библиотека").navigationBarTitleDisplayMode(.inline).blinkScreen()
        .searchable(text: $search, prompt: "Название сервера или протокол")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { importPresented = true } label: { Image(systemName: "plus") }.accessibilityLabel("Добавить конфигурацию") } }
        .animation(reduceMotion ? nil : BlinkTheme.spring, value: profiles.count)
        .animation(reduceMotion ? nil : BlinkTheme.spring, value: filter)
        .sheet(isPresented: $importPresented, onDismiss: { input = "" }) { importSheet }
        .sheet(item: $details) { ProfileDetailsView(profile: $0) }
        .sheet(isPresented: $guidePresented) { ProtocolGuideView() }
        .confirmationDialog("Удалить этот профиль?", isPresented: $deletePresented, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { if let profile = pendingDelete { profiles.removeAll { $0.id == profile.id }; save() }; pendingDelete = nil }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        }
        .task { load() }
        .sheet(isPresented: $scannerPresented, onDismiss: {
            if let text = scannedText { scannedText = nil; importText(text) }
        }) {
            QRScannerView(onResult: { text in scannedText = text; scannerPresented = false }, onFailure: { error in message = error; scannerPresented = false })
        }
        .onChange(of: selectedPhoto) { if let item = $0 { readQRPhoto(item) } }
        .fileImporter(isPresented: $filePresented, allowedContentTypes: [.data, .plainText, .json]) { result in
            do {
                let url = try result.get(); let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: 1048577) ?? Data()
                guard data.count <= 1048576, let text = String(data: data, encoding: .utf8) else { throw UniversalProfileError.invalid }
                importText(text)
            } catch { message = "Файл не прочитан или превышает 1 МБ." }
        }
        .onDisappear { input = ""; importID = UUID(); importTask?.cancel(); importing = false; photoID = UUID(); photoTask?.cancel(); readingPhoto = false }
    }
    private var importHub: some View {
        VStack(alignment: .leading, spacing: 14) {
            BlinkSectionHeading(title: "Добавить подключение")
            LazyVGrid(columns: textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button { importPresented = true } label: { ImportSourceTile(title: "Ссылка или текст", symbol: "link", detail: "Вставить конфигурацию") }
                Button { scannerPresented = true } label: { ImportSourceTile(title: "Сканировать QR", symbol: "qrcode.viewfinder", detail: "Открыть камеру") }
                PhotosPicker(selection: $selectedPhoto, matching: .images) { ImportSourceTile(title: "QR из фото", symbol: "photo", detail: "Выбрать изображение") }
                Button { filePresented = true } label: { ImportSourceTile(title: "Из файла", symbol: "doc.text", detail: "JSON, YAML или .conf") }
            }.buttonStyle(BlinkTileStyle()).disabled(importing || readingPhoto)
        }
    }
    private var importSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Обычный VPN", systemImage: ConnectionRoute.direct.symbol).foregroundStyle(BlinkTheme.accent)
                    Text("Вставьте HTTPS-подписку, VPN-ссылку или текст конфигурации провайдера.").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $input).frame(minHeight: 160).font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().disabled(importing)
                    PasteButton(payloadType: String.self) { if let value = $0.first { input = value } }.disabled(importing)
                } header: { Text("Ваша конфигурация") }
                Section {
                    Button { importText(input) } label: {
                        HStack { Spacer(); if importing { ProgressView() }; Text(importing ? "Добавляем…" : "Добавить в библиотеку"); Spacer() }
                    }.disabled(importing || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    Text("Поддерживаются отдельные ссылки и списки серверов, подписки plain/base64, Xray JSON, узлы Clash YAML и WireGuard / AmneziaWG. Для Vokop используйте режим «Через VK».").font(.footnote).foregroundStyle(.secondary)
                }
            }.blinkScreen().navigationTitle("Добавить VPN").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { importPresented = false }.disabled(importing) } }
                .interactiveDismissDisabled(importing)
        }
    }
    private func profileCard(_ profile: UniversalProfile) -> some View {
        let info = VPNProtocolInfo.describe(kind: profile.kind, source: profile.source)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                BlinkBadge(symbol: info.symbol)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text(profile.subscriptionURL.flatMap { URLComponents(string: $0)?.host } ?? "Отдельная конфигурация").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button { details = profile } label: { Label("О конфигурации", systemImage: "info.circle") }
                    Button(role: .destructive) { pendingDelete = profile; deletePresented = true } label: { Label("Удалить", systemImage: "trash") }.disabled(xray.hasActiveConnection)
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Действия с профилем \(profile.name)")
            }
            ViewThatFits(in: .horizontal) {
                HStack { BlinkPill(title: info.title); BlinkPill(title: "Напрямую", symbol: "arrow.right") }
                VStack(alignment: .leading) { BlinkPill(title: info.title); BlinkPill(title: "Напрямую", symbol: "arrow.right") }
            }
            Button { details = profile } label: {
                Label("Что это за конфигурация?", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
            }.buttonStyle(.plain)
            Button { Task { await xray.connectUniversal(source: profile.source, name: profile.name, secrets: container.secretStore, diagnosticURL: profile.subscriptionURL) } } label: { Label("Подключить", systemImage: "power") }
                .buttonStyle(BlinkActionStyle(prominent: true)).disabled(xray.hasActiveConnection)
        }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
    }
    private func readQRPhoto(_ item: PhotosPickerItem) {
        photoTask?.cancel()
        let id = UUID(); photoID = id
        readingPhoto = true; message = nil
        photoTask = Task { @MainActor in
            defer { if photoID == id { readingPhoto = false; selectedPhoto = nil } }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw QRImageError.unreadable }
                try Task.checkCancellation()
                let text = try await Task.detached(priority: .userInitiated) { try QRImageDecoder.decode(data) }.value
                try Task.checkCancellation()
                importText(text)
            } catch is CancellationError { }
            catch let error as QRImageError { if photoID == id { message = error.localizedDescription } }
            catch { if photoID == id && !Task.isCancelled { message = "Не удалось прочитать QR из фото. Выберите другое изображение." } }
        }
    }
    private func importText(_ source: String) {
        guard !importing else { return }; importing = true; message = nil; let id = UUID(); importID = id
        importTask = Task { @MainActor in
            defer { if importID == id { importing = false } }
            do {
                let text: String
                let subscriptionURL: String?
                switch try ProfileImportInput.parse(source) {
                case .subscription(let url):
                    subscriptionURL = url
                    let data = try await SecureSubscriptionHTTP().fetch(url)
                    guard let value = String(data: data, encoding: .utf8) else { throw UniversalProfileError.invalid }
                    text = value
                case .configuration(let value):
                    subscriptionURL = nil; text = value
                }
                try Task.checkCancellation()
                guard importID == id else { return }
                var (added, rejected, notice) = try await Task.detached(priority: .userInitiated) {
                    try UniversalProfile.imported(text)
                }.value
                try Task.checkCancellation()
                guard importID == id else { return }
                if let url = subscriptionURL { for i in added.indices { added[i].subscriptionURL = url } }
                let retained = subscriptionURL.map { url in profiles.filter { $0.subscriptionURL != url } } ?? profiles
                guard retained.count + added.count <= 1024 else { throw UniversalProfileError.invalid }
                let next = retained + added; let data = try JSONEncoder().encode(next)
                guard data.count <= 4194304 else { throw UniversalProfileError.invalid }
                try container.secretStore.save(String(decoding: data, as: UTF8.self), profileID: vaultID, kind: .universalProfiles)
                profiles = next; input = ""; importPresented = false; message = "Добавлено: \(added.count). Отклонено: \(rejected). \(notice)"
            } catch is CancellationError { }
            catch let error as ProfileImportInputError { if importID == id { message = error.localizedDescription } }
            catch let error as SubscriptionError { if importID == id { message = error.localizedDescription } }
            catch let error as NetworkRequestError { if importID == id { message = error.localizedDescription } }
            catch { if importID == id { message = "Импорт не выполнен. Проверьте протокол, настройки и HTTPS-подписку." } }
        }
    }
    private func load() { do { if let value = try container.secretStore.read(profileID: vaultID, kind: .universalProfiles) { profiles = try JSONDecoder().decode([UniversalProfile].self, from: Data(value.utf8)) } } catch { message = "Не удалось прочитать защищённые профили." } }
    private func save() { do { let data = try JSONEncoder().encode(profiles); try container.secretStore.save(String(decoding: data, as: UTF8.self), profileID: vaultID, kind: .universalProfiles) } catch { message = "Не удалось сохранить профили." } }
}


private struct ImportSourceTile: View {
    let title: String
    let symbol: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.title2.weight(.medium)).foregroundStyle(BlinkTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(BlinkTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(BlinkTheme.stroke) }
    }
}
