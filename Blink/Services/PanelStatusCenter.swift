import Foundation
import Combine

@MainActor final class PanelStatusCenter: ObservableObject {
    static let shared = PanelStatusCenter()
    @Published private(set) var status: PanelServiceStatus?
    private var subscription = ""
    private var ticks = 0
    func refresh() async {
        ticks += 1
        if subscription.isEmpty || ticks % 12 == 0 {
            let id = UUID(uuidString: "57f8b06a-c211-4b4f-8525-14cb2e7a882e")!
            if let raw = try? KeychainSecretStore().read(profileID: id, kind: .subscriptionURL),
               let state = try? JSONDecoder().decode(SavedVokopSubscription.self, from: Data(raw.utf8)) {
                if subscription != state.url { status = nil }; subscription = state.url
            } else { subscription = ""; status = nil }
        }
        guard !subscription.isEmpty, let url = try? VokopSubscriptionClient.statusURL(subscription: subscription) else { return }
        do {
            let data = try await VokopSubscriptionClient.fetchControl(url)
            try Task.checkCancellation()
            let value = try JSONDecoder().decode(PanelServiceStatus.self, from: data)
            guard value.revision >= 0, value.message.utf8.count <= 4000 else { return }
            status = value
        } catch { }
    }
}
