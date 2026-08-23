import SwiftUI
import UniformTypeIdentifiers

struct ProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var profile: VPNProfile

    init(profile: VPNProfile) { self.profile = profile }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        profile = try decoder.decode(VPNProfile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try encoder.encode(profile))
    }
}
