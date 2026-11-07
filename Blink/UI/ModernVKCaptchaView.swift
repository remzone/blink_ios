import SwiftUI
import UIKit

struct ModernVKCaptchaView: View {
    @EnvironmentObject private var authorizer: VKPreflightAuthorizer
    let challenge: VKPreflightAuthorizer.ModernChallenge
    var body: some View {
        NavigationStack {
            CaptchaController(controller: challenge.controller)
                .navigationTitle("Проверка VK")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") { authorizer.cancelChallenge(challenge.id) }
                    }
                }
        }
        .interactiveDismissDisabled()
        .onDisappear { authorizer.cancelChallenge(challenge.id) }
    }
}

private struct CaptchaController: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ controller: UIViewController, context: Context) { }
}
