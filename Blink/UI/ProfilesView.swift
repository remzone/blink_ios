import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var editingProfile: VPNProfile?
    @State private var createPresented = false
    @State private var errorMessage: String?
    @State private var importPresented = false

    var body: some View {
        List(selection: $container.profileStore.selectedProfileID) {
            if container.profileStore.profiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "shield.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No profiles").font(.headline)
                    Text("Create your first VPN connection.").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else {
                ForEach(container.profileStore.profiles) { profile in
                    Button { container.profileStore.selectedProfileID = profile.id } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.blue).font(.title2)
                            VStack(alignment: .leading) {
                                Text(profile.name).foregroundStyle(.primary)
                                Text("\(profile.server):\(profile.port)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if container.profileStore.selectedProfileID == profile.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            Button { editingProfile = profile } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        }.padding(.vertical, 5)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { delete(profile) } }
                }
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            Menu {
                Button { createPresented = true } label: { Label("Create Profile", systemImage: "plus") }
                Button { importPresented = true } label: { Label("Import JSON", systemImage: "square.and.arrow.down") }
            } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $createPresented) { NavigationStack { ProfileEditorView(profile: VPNProfile()) } }
        .sheet(item: $editingProfile) { NavigationStack { ProfileEditorView(profile: $0) } }
        .fileImporter(isPresented: $importPresented, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var profile = try decoder.decode(VPNProfile.self, from: data)
                profile.id = UUID(); profile.name += " (Imported)"
                try container.profileStore.upsert(profile)
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") {} } message: { Text(errorMessage ?? "") }
    }

    private func delete(_ profile: VPNProfile) {
        do { try container.profileStore.delete(profile); try container.secretStore.delete(profileID: profile.id) }
        catch { errorMessage = error.localizedDescription }
    }
}
