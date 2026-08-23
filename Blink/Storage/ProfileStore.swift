import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [VPNProfile] = []
    @Published var selectedProfileID: UUID? = nil { didSet { saveSelection() } }

    var selectedProfile: VPNProfile? { profiles.first { $0.id == selectedProfileID } }
    private let fileURL: URL
    private let selectionURL: URL
    private let logStore: LogStore
    private let encoder: JSONEncoder

    init(fileManager: FileManager = .default, logStore: LogStore) {
        self.logStore = logStore
        let root = SharedConstants.storageDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("profiles.json")
        self.selectionURL = root.appendingPathComponent("selection.json")
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        load()
    }

    func upsert(_ profile: VPNProfile) throws {
        var value = profile
        value.updatedAt = .now
        if let index = profiles.firstIndex(where: { $0.id == value.id }) { profiles[index] = value }
        else { profiles.append(value) }
        if selectedProfileID == nil { selectedProfileID = value.id }
        try persist()
        logStore.add(.info, source: "Profiles", message: "Profile saved")
    }

    func delete(_ profile: VPNProfile) throws {
        profiles.removeAll { $0.id == profile.id }
        if selectedProfileID == profile.id { selectedProfileID = profiles.first?.id }
        try persist()
        logStore.add(.info, source: "Profiles", message: "Profile deleted")
    }

    private func load() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let values = try? decoder.decode([VPNProfile].self, from: data) { profiles = values }
        if let data = try? Data(contentsOf: selectionURL),
           let id = try? decoder.decode(UUID.self, from: data),
           profiles.contains(where: { $0.id == id }) { selectedProfileID = id }
    }

    private func persist() throws { try encoder.encode(profiles).write(to: fileURL, options: .atomic) }
    private func saveSelection() { try? encoder.encode(selectedProfileID).write(to: selectionURL, options: .atomic) }
}
