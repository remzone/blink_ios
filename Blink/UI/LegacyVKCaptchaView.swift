import SwiftUI
import UIKit

struct LegacyVKCaptchaView: View {
    @EnvironmentObject private var authorizer: VKPreflightAuthorizer
    let challenge: VKPreflightAuthorizer.LegacyChallenge
    @State private var image: UIImage?
    @State private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Ручная проверка VK") {
                    if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180) } else { Text("Загрузка изображения…") }
                    SecureField("Код с изображения", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Продолжить") { authorizer.submitLegacy(code) }.disabled(code.isEmpty || image == nil)
                }
            }.navigationTitle("Проверка VK").toolbar { Button("Отмена", role: .cancel) { authorizer.cancelLegacy() } }
        }.task(id: challenge.id) {
            let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil; configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration, delegate: SecureSubscriptionHTTP(), delegateQueue: nil); defer { session.invalidateAndCancel() }
            do {
                let (bytes, response) = try await session.bytes(from: challenge.image)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                var data = Data(); for try await byte in bytes { guard data.count < 1_048_576 else { return }; data.append(byte) }
                image = UIImage(data: data)
            } catch { }
        }.onDisappear { code = "" }
    }
}
