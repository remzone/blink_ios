import Foundation

enum SharedConstants {
    static let appGroup = "group.com.blink.tunnel"
    static let tunnelBundleIdentifier = "com.blink.tunnel.PacketTunnel"
    static let profileIDKey = "profileID"

    static func storageDirectory(fileManager: FileManager = .default) -> URL {
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group.appendingPathComponent("Library/Application Support/Blink", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blink", isDirectory: true)
    }
}
