import SwiftUI
import UniformTypeIdentifiers

struct UniversalProfilesView: View {
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var textSize
    private var gridColumns: [GridItem] { widthClass == .compact || textSize.isAccessibilitySize ? [GridItem(.flexible(minimum: 0))] : [GridItem(.adaptive(minimum: 250), spacing: 18)] }
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var xray: XrayVPNController
    @State private var profiles: [UniversalProfile] = []
    @State private var input = ""
    @State private var search = ""
    @State private var pendingDelete: UniversalProfile?
    @State private var deletePresented = false
    private var filtered: [UniversalProfile] { profiles.filter { search.isEmpty || ($0.name + " " + $0.kind).localizedCaseInsensitiveContains(search) } }
    @State private var message: String?
    @State private var importing = false
    @State private var filePresented = false
    @State private var importID = UUID()
    @State private var importTask: Task<Void, Never>?
    private let vaultID = UUID(uuidString: "81487391-25f0-41c7-a31c-1454e4c18400")!
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BlinkHeader(title: "Мир ближе,\nчем кажется.", subtitle: "Твои серверы, страны и подписки — в одном месте.")
                VStack(alignment: .leading, spacing: 16) {
                    Label("Добавить подключение", systemImage: "plus.circle").font(.headline)
                    SecureField("URI или HTTPS-подписка", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    Button { importText(input) } label: { Label(importing ? "Добавляем…" : "Добавить в Blink", systemImage: "plus") }.buttonStyle(BlinkActionStyle(prominent: true)).disabled(importing || input.isEmpty)
                    Button { filePresented = true } label: { Label("Открыть файл конфигурации", systemImage: "doc.badge.plus") }.buttonStyle(BlinkActionStyle()).disabled(importing)
                    if importing { ProgressView("Проверяем профили…") }
                    Text("Xray, WireGuard, AmneziaWG, TUIC и Hysteria. Обычные подключения работают без VK и CAPTCHA.").font(.caption).foregroundStyle(.secondary)
                }.blinkCard()
                if let message { BlinkNotice(message: message) }
                if !profiles.isEmpty {
                    HStack { Text("Твои серверы").font(.title2.weight(.semibold)); Spacer(); Text("\(profiles.count)").font(.caption.monospacedDigit()).padding(8).background(BlinkTheme.accent.opacity(0.12), in: Capsule()) }
                }
                if profiles.isEmpty {
                    BlinkEmptyState(symbol: "globe.europe.africa", title: "Твой мир начинается здесь", detail: "Добавь ссылку провайдера, подписку или файл конфигурации. Серверы появятся отдельными карточками.").blinkCard()
                } else if filtered.isEmpty {
                    BlinkEmptyState(symbol: "magnifyingglass", title: "Такого сервера пока нет", detail: "Попробуй другое название страны или очисти поиск.")
                }
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 18) {
                    ForEach(filtered) { profile in
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { BlinkBadge(symbol: "globe.europe.africa"); Spacer(); Text(profile.kind.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                            Text(profile.name).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Button { Task { await xray.connectUniversal(source: profile.source, name: profile.name, secrets: container.secretStore) } } label: { Label("Подключить", systemImage: "power") }.buttonStyle(BlinkActionStyle(prominent: true)).disabled(xray.busy)
                            Button(role: .destructive) { pendingDelete = profile; deletePresented = true } label: { Label("Удалить профиль", systemImage: "trash").font(.caption) }.disabled(xray.busy || xray.isConnected)
                        }.frame(maxWidth: .infinity, alignment: .leading).blinkCard()
                    }
                }
                ForEach(Array(Set(profiles.compactMap(\.subscriptionURL))).sorted(), id: \.self) { url in
                    Button { importText(url) } label: { BlinkDestination(title: "Обновить подписку", subtitle: URLComponents(string: url)?.host ?? "Провайдер", symbol: "arrow.clockwise") }.buttonStyle(BlinkActionStyle()).disabled(importing)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Label("Соединение", systemImage: "waveform.path.ecg").font(.headline)
                    Text(xray.status).font(.subheadline).foregroundStyle(.secondary)
                    if let error = xray.errorMessage { BlinkNotice(message: error, symbol: "exclamationmark.circle") }
                    Button { Task { await xray.refreshTransportStatus() } } label: { Label("Проверить состояние", systemImage: "arrow.clockwise") }.buttonStyle(BlinkActionStyle())
                    Button { xray.disconnect() } label: { Label("Отключить туннель", systemImage: "power") }.buttonStyle(BlinkActionStyle()).disabled(!xray.isConnected && !xray.busy)
                }.blinkCard()
            }.padding(22).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.navigationTitle("Подключения").navigationBarTitleDisplayMode(.inline).blinkScreen()
        .searchable(text: $search, prompt: "Страна или название сервера")
        .confirmationDialog("Удалить этот профиль?", isPresented: $deletePresented, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { if let profile = pendingDelete { profiles.removeAll { $0.id == profile.id }; save() }; pendingDelete = nil }
            Button("Оставить", role: .cancel) { pendingDelete = nil }
        }
        .task { load() }
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
        .onDisappear { input = ""; importID = UUID(); importTask?.cancel(); importing = false }
    }
    private func importText(_ source: String) {
        guard !importing else { return }; importing = true; message = nil; let id = UUID(); importID = id
        importTask = Task { @MainActor in
            defer { if importID == id { importing = false } }
            do {
                var text = source; var subscriptionURL: String?
                if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("https://"), URLComponents(string: source.trimmingCharacters(in: .whitespacesAndNewlines))?.user == nil {
                    subscriptionURL = source.trimmingCharacters(in: .whitespacesAndNewlines)
                    let data = try await SecureSubscriptionHTTP().fetch(subscriptionURL!)
                    guard let value = String(data: data, encoding: .utf8) else { throw UniversalProfileError.invalid }; text = value
                }
                try Task.checkCancellation()
                guard importID == id else { return }
                var (added, rejected, notice) = try UniversalProfile.imported(text)
                if let url = subscriptionURL { for i in added.indices { added[i].subscriptionURL = url } }
                let retained = subscriptionURL.map { url in profiles.filter { $0.subscriptionURL != url } } ?? profiles
                guard retained.count + added.count <= 1024 else { throw UniversalProfileError.invalid }
                let next = retained + added; let data = try JSONEncoder().encode(next)
                guard data.count <= 4194304 else { throw UniversalProfileError.invalid }
                try container.secretStore.save(String(decoding: data, as: UTF8.self), profileID: vaultID, kind: .universalProfiles)
                profiles = next; input = ""; message = "Добавлено: \(added.count). Отклонено: \(rejected). \(notice)"
            } catch is CancellationError { }
            catch { if importID == id { message = "Импорт не выполнен. Проверьте протокол, настройки и HTTPS-подписку." } }
        }
    }
    private func load() { do { if let value = try container.secretStore.read(profileID: vaultID, kind: .universalProfiles) { profiles = try JSONDecoder().decode([UniversalProfile].self, from: Data(value.utf8)) } } catch { message = "Не удалось прочитать защищённые профили." } }
    private func save() { do { let data = try JSONEncoder().encode(profiles); try container.secretStore.save(String(decoding: data, as: UTF8.self), profileID: vaultID, kind: .universalProfiles) } catch { message = "Не удалось сохранить профили." } }
}
