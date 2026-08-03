import Foundation
import Security

/// `SecretStore` backed by the macOS Keychain (generic password items).
///
/// One item per `SecretKey`, all under a single service so the user sees a
/// coherent group in Keychain Access.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "io.github.voiceinput.VoiceInput"

    private let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func secret(for key: SecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw VoiceInputError.keychainFailure("保存された値を読み取れませんでした。")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw Self.failure(status)
        }
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        guard let value, !value.isEmpty else {
            try delete(key)
            return
        }
        let data = Data(value.utf8)
        let query = baseQuery(for: key)

        // Update-or-add: a plain add on an existing item fails with errSecDuplicateItem.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.failure(addStatus) }
        default:
            throw Self.failure(updateStatus)
        }
    }

    public func hasSecret(for key: SecretKey) -> Bool {
        ((try? secret(for: key)) ?? nil) != nil
    }

    private func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.failure(status)
        }
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    private static func failure(_ status: OSStatus) -> VoiceInputError {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return .keychainFailure(message ?? "OSStatus \(status)")
    }
}
