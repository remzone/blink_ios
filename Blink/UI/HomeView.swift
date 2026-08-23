import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var model = HomeViewModel()
    @State private var metrics = TunnelMetrics.empty

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                powerButton
                Text(model.state.title).font(.title3.weight(.semibold))
                Text(statusSubtitle).foregroundStyle(.secondary)
                connectionCard
            }
            .padding(20)
        }
        .background(background)
        .navigationBarHidden(true)
        .task { model.observe(container.vpnService) }
        .task(id: model.state.title) {
            guard case .connected = model.state, let service = container.vpnService as? SystemVPNService else {
                metrics = .empty; return
            }
            while !Task.isCancelled {
                metrics = await service.metrics() ?? metrics
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .alert("Blink", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled").font(.title).foregroundStyle(.cyan)
            Text("Blink").font(.largeTitle.bold())
            Spacer()
            if let profile = container.profileStore.selectedProfile {
                Text(profile.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var powerButton: some View {
        Button { Task { await model.toggle(container: container) } } label: {
            ZStack {
                Circle().fill(.blue.opacity(0.14)).frame(width: 250, height: 250)
                Circle().stroke(.blue.opacity(0.45), lineWidth: 2).frame(width: 205, height: 205)
                Circle().fill(LinearGradient(colors: [.blue.opacity(0.9), .indigo], startPoint: .top, endPoint: .bottom))
                    .frame(width: 160, height: 160).shadow(color: .blue.opacity(0.65), radius: 24)
                if model.state.isBusy { ProgressView().scaleEffect(1.5).tint(.white) }
                else { Image(systemName: "power").font(.system(size: 62, weight: .light)).foregroundStyle(.white) }
            }
        }.buttonStyle(.plain).disabled(model.state.isBusy)
    }

    private var connectionCard: some View {
        VStack(spacing: 14) {
            row("Server", container.profileStore.selectedProfile.map { "\($0.server):\($0.port)" } ?? "—")
            Divider(); row("Latency", "—")
            Divider(); row("Upload", ByteCountFormatter.string(fromByteCount: metrics.uploadedBytes, countStyle: .binary))
            Divider(); row("Download", ByteCountFormatter.string(fromByteCount: metrics.downloadedBytes, countStyle: .binary))
        }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1) }
    }
    private var statusSubtitle: String { container.profileStore.selectedProfile == nil ? "Create a profile to begin" : "Tap the button to connect" }
    private var background: some View { LinearGradient(colors: [Color(red: 0.02, green: 0.06, blue: 0.12), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea() }
}
