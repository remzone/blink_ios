import SwiftUI
import UniformTypeIdentifiers

struct UniversalProfilesView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var xray: XrayVPNController
    @State private var profiles: [UniversalProfile] = []
    @State private var input = ""
    @State private var message: String?
    @State private var importing = false
    @State private var filePresented = false
    @State private var importID = UUID()
    @State private var importTask: Task<Void, Never>?
    private let vaultID = UUID(uuidString: "81487391-25f0-41c7-a31c-1454e4c18400")!
    var body: some View {
        Form {
            Section("Добавить VPN") {
                SecureField("URI или HTTPS-подписка", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(importing ? "Импорт…" : "Импортировать") { importText(input) }.disabled(importing || input.isEmpty)
                Button("Импортировать .conf или текстовый файл") { filePresented = true }.disabled(importing)
                Text("VLESS, VMess, Trojan, Shadowsocks, SOCKS, Hysteria2, WireGuard и AmneziaWG. Обычные профили работают без VK и CAPTCHA.").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            Section("VPN-подписки") {
                ForEach(Array(Set(profiles.compactMap(\.subscriptionURL))).sorted(), id: \.self) { url in
                    Button("Обновить: \(URLComponents(string: url)?.host ?? "подписка")") { importText(url) }.disabled(importing)
                }
            }
            Section("Профили") {
                if profiles.isEmpty { Text("Импортируйте ссылку, подписку или конфигурацию WireGuard/AmneziaWG.").foregroundStyle(.secondary) }
                ForEach(profiles) { profile in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.name).font(.headline).textSelection(.enabled)
                        Text(profile.kind.uppercased()).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Подключить") { Task { await xray.connectUniversal(source: profile.source, name: profile.name, secrets: container.secretStore) } }.disabled(xray.busy)
                            Spacer()
                            Button("Удалить", role: .destructive) { profiles.removeAll { $0.id == profile.id }; save() }
                        }
                    }.padding(.vertical, 5)
                }
            }
            Section("Соединение") {
                Text(xray.status)
                if let error = xray.errorMessage { Text(error).foregroundStyle(.red) }
                Button("Проверить состояние транспорта") { Task { await xray.refreshTransportStatus() } }
                Button("Отключить", role: .destructive) { xray.disconnect() }
                Text("Системный статус VPN не подтверждает доступ к интернету. Для Xray используется IPv4; IPv6 из явной конфигурации WireGuard требует отдельной проверки сервера.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("VPN-профили")
        .task { load() }
        .fileImporter(isPresented: $filePresented, allowedContentTypes: [.data, .plainText, .json]) { result in
            do {
                let url = try result.get(); let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: 131073) ?? Data()
                guard data.count <= 131072, let text = String(data: data, encoding: .utf8) else { throw UniversalProfileError.invalid }
                importText(text)
            } catch { message = "Файл не прочитан или превышает 128 КБ." }
        }
        .onDisappear { input = ""; importID = UUID(); importTask?.cancel(); importing = false }
    }
    private func importText(_ source: String) {
        guard !importing else { return }; importing = true; message = nil; let id = UUID(); importID = id
        importTask = Task { @MainActor in
            defer { if importID == id { importing = false } }
            do {
                var text = source; var subscriptionURL: String?
                if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("https://") {
                    subscriptionURL = source.trimmingCharacters(in: .whitespacesAndNewlines)
                    let data = try await SecureSubscriptionHTTP().fetch(subscriptionURL!)
                    guard let value = String(data: data, encoding: .utf8) else { throw UniversalProfileError.invalid }; text = value
                }
                try Task.checkCancellation()
                guard importID == id else { return }
                var (added, rejected) = try UniversalProfile.imported(text)
                if let url = subscriptionURL { for i in added.indices { added[i].subscriptionURL = url } }
                let retained = subscriptionURL.map { url in profiles.filter { $0.subscriptionURL != url } } ?? profiles
                guard retained.count + added.count <= 256 else { throw UniversalProfileError.invalid }
                let next = retained + added; let data = try JSONEncoder().encode(next)
                guard data.count <= 524288 else { throw UniversalProfileError.invalid }
                try container.secretStore.save(String(decoding: data, as: UTF8.self), profileID: vaultID, kind: .universalProfiles)
                profiles = next; input = ""; message = "Добавлено: \(added.count). Отклонено: \(rejected)."
            } catch is CancellationError { }
            catch { if importID == id { message = "Импорт не выполнен. Проверьте протокол, настройки и HTTPS-подписку." } }
        }
    }
    private func load() { do { if let value = try container.secretStore.read(profileID: vaultID, kind: .universalProfiles) { profiles = try JSONDecoder().decode([UniversalProfile].self, from: Data(value.utf8)) } } catch { message = "Не удалось прочитать защищённые профили." } }
    private func save() { do { let data = try JSONEncoder().encode(profiles); try container.secretStore.save(String(decoding: data, as: UTF8.self), profileID: vaultID, kind: .universalProfiles) } catch { message = "Не удалось сохранить профили." } }
}
