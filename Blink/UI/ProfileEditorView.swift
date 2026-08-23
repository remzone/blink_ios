import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct ProfileEditorView: View {
    enum Mode: String, CaseIterable { case simple = "Simple", advanced = "Advanced JSON" }
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var profile: VPNProfile
    @State private var secrets = ProfileSecrets()
    @State private var mode = Mode.simple
    @State private var json = ""
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var exportPresented = false

    init(profile: VPNProfile) { _profile = State(initialValue: profile) }

    var body: some View {
        Form {
            Picker("Editor", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented)
            if mode == .simple { simpleForm } else { advancedForm }
        }
        .navigationTitle(profile.name.isEmpty ? "New Profile" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItemGroup(placement: .confirmationAction) {
                Button { exportPresented = true } label: { Image(systemName: "square.and.arrow.up") }
                Button("Save", action: save)
            }
        }
        .task { loadOnce() }
        .onChange(of: mode) { newMode in if newMode == .advanced { encodeJSON() } }
        .alert("Cannot Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") {} } message: { Text(errorMessage ?? "") }
        .fileExporter(isPresented: $exportPresented, document: ProfileDocument(profile: profile), contentType: .json, defaultFilename: safeFilename) { result in
            if case let .failure(error) = result { errorMessage = error.localizedDescription }
        }
    }

    private var simpleForm: some View {
        Group {
            Section("Connection") {
                TextField("My VPN", text: $profile.name)
                TextField("example.com", text: $profile.server).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("56000", value: $profile.port, format: .number).keyboardType(.numberPad)
            }
            Section("WireGuard") {
                SecureField("Private key", text: $secrets.wireGuardPrivateKey).textInputAutocapitalization(.never)
                Button("Generate client key") { generatePrivateKey() }
                if let clientPublicKey {
                    LabeledContent("Client public key") { Text(clientPublicKey).font(.caption.monospaced()).textSelection(.enabled) }
                }
                TextField("Server public key", text: $profile.wireGuard.publicKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Address", text: $profile.wireGuard.address).textInputAutocapitalization(.never)
                TextField("DNS", text: $profile.wireGuard.dns).textInputAutocapitalization(.never)
            }
            Section("Free TURN") {
                TextField("VK Call URL", text: $profile.freeTurn.vkLink, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Obfuscation key", text: $secrets.obfuscationKey)
                TextField("Profile", text: $profile.freeTurn.obfProfile).textInputAutocapitalization(.never)
            }
            Section("Notes") { TextField("Optional notes", text: $profile.notes, axis: .vertical).lineLimit(3...6) }
        }
    }

    private var advancedForm: some View {
        Section {
            TextEditor(text: $json).font(.system(.body, design: .monospaced)).frame(minHeight: 400)
        } footer: { Text("Secrets are deliberately excluded from JSON export and remain in Keychain.") }
    }

    private func loadOnce() {
        guard !loaded else { return }; loaded = true
        do {
            secrets.wireGuardPrivateKey = try container.secretStore.read(profileID: profile.id, kind: .wireGuardPrivateKey) ?? ""
            secrets.obfuscationKey = try container.secretStore.read(profileID: profile.id, kind: .obfuscationKey) ?? ""
        } catch { errorMessage = error.localizedDescription }
        encodeJSON()
    }

    private func encodeJSON() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(profile) { json = String(decoding: data, as: UTF8.self) }
    }

    private func save() {
        do {
            if mode == .advanced {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                profile = try decoder.decode(VPNProfile.self, from: Data(json.utf8))
            }
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let server = profile.server.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ValidationError("Name is required.") }
            guard !server.isEmpty, !server.contains(" ") else { throw ValidationError("Enter a valid server hostname or IP address.") }
            guard (1...65535).contains(profile.port) else { throw ValidationError("Port must be between 1 and 65535.") }
            guard Data(base64Encoded: secrets.wireGuardPrivateKey)?.count == 32 else { throw ValidationError("WireGuard private key must be a Base64-encoded 32-byte key.") }
            guard Data(base64Encoded: profile.wireGuard.publicKey)?.count == 32 else { throw ValidationError("Server public key must be a Base64-encoded 32-byte key.") }
            guard let vkURL = URL(string: profile.freeTurn.vkLink), vkURL.scheme == "https", vkURL.host != nil else { throw ValidationError("Enter a valid HTTPS VK Call URL.") }
            profile.name = name; profile.server = server
            try container.secretStore.save(secrets.wireGuardPrivateKey, profileID: profile.id, kind: .wireGuardPrivateKey)
            try container.secretStore.save(secrets.obfuscationKey, profileID: profile.id, kind: .obfuscationKey)
            try container.profileStore.upsert(profile)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private var safeFilename: String {
        let value = profile.name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        return value.isEmpty ? "blink-profile" : value
    }

    private func generatePrivateKey() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        secrets.wireGuardPrivateKey = key.rawRepresentation.base64EncodedString()
    }

    private var clientPublicKey: String? {
        guard let data = Data(base64Encoded: secrets.wireGuardPrivateKey), data.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }
}

private struct ValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
