import Foundation
import Security

enum SecretKind: String { case wireGuardPrivateKey, obfuscationKey }

protocol SecretStore {
    func save(_ value: String, profileID: UUID, kind: SecretKind) throws
    func read(profileID: UUID, kind: SecretKind) throws -> String?
    func delete(profileID: UUID) throws
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    var errorDescription: String? { "Keychain error (\(status))" }
    private var status: OSStatus { if case let .unexpectedStatus(value) = self { value } else { errSecInternalError } }
}

final class KeychainSecretStore: SecretStore {
    private let service = "com.blink.tunnel.profile-secrets"
    private var accessGroup: String? { Bundle.main.object(forInfoDictionaryKey: "BlinkKeychainAccessGroup") as? String }

    func save(_ value: String, profileID: UUID, kind: SecretKind) throws {
        let account = key(profileID, kind)
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func read(profileID: UUID, kind: SecretKind) throws -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key(profileID, kind),
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(profileID: UUID) throws {
        for kind in [SecretKind.wireGuardPrivateKey, .obfuscationKey] {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: key(profileID, kind)]
            if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }

    private func key(_ id: UUID, _ kind: SecretKind) -> String { "\(id.uuidString).\(kind.rawValue)" }
}
