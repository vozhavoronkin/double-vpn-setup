import Foundation
import Security

/// Хранилище секретов в macOS Keychain (generic passwords).
///
/// Аккаунт формируется из идентификатора профиля и назначения секрета,
/// поэтому секреты никогда не попадают в UserDefaults/файлы профиля.
public final class KeychainStore: @unchecked Sendable {
    public enum SecretKind: String, Sendable {
        case password
        case passphrase
    }

    private let service: String

    public init(service: String = "ru.vpnchain.app") {
        self.service = service
    }

    /// Аккаунт для пары (профиль, назначение).
    public static func account(profileID: UUID, kind: SecretKind) -> String {
        "\(profileID.uuidString).\(kind.rawValue)"
    }

    // MARK: CRUD

    public func setSecret(_ secret: String, profileID: UUID, kind: SecretKind) throws {
        let account = Self.account(profileID: profileID, kind: kind)
        let data = Data(secret.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.addFailed(code: Int(addStatus))
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.updateFailed(code: Int(updateStatus))
        }
    }

    public func secret(profileID: UUID, kind: SecretKind) -> String? {
        let account = Self.account(profileID: profileID, kind: kind)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func deleteSecret(profileID: UUID, kind: SecretKind) {
        let account = Self.account(profileID: profileID, kind: kind)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func deleteAllSecrets(profileID: UUID) {
        deleteSecret(profileID: profileID, kind: .password)
        deleteSecret(profileID: profileID, kind: .passphrase)
    }

    /// Определён ли секрет (без чтения значения).
    public func hasSecret(profileID: UUID, kind: SecretKind) -> Bool {
        secret(profileID: profileID, kind: kind) != nil
    }
}

public enum KeychainError: Error, Equatable {
    case addFailed(code: Int)
    case updateFailed(code: Int)
}
