import Foundation

/// Хранилище профилей подключений: несекретные данные — UserDefaults (JSON),
/// секреты — Keychain. Единая точка CRUD для экрана «Подключения» (задача 2.5)
/// и для сборки `SSHConnectOptions` при выполнении операций.
public final class ProfileStore: @unchecked Sendable {
    private static let storageKey = "vpnchain.profiles"

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    // MARK: Профили

    public var profiles: [ConnectionProfile] {
        lock.lock()
        defer { lock.unlock() }
        return profilesLocked()
    }

    public func profile(id: UUID) -> ConnectionProfile? {
        lock.lock()
        defer { lock.unlock() }
        return profilesLocked().first { $0.id == id }
    }

    /// Добавляет или обновляет профиль. Возвращает ошибку валидации, если профиль некорректен.
    @discardableResult
    public func upsert(_ profile: ConnectionProfile) -> ConnectionProfile.ValidationError? {
        guard let error = profile.validate() else {
            lock.lock()
            defer { lock.unlock() }
            var all = profilesLocked()
            if let index = all.firstIndex(where: { $0.id == profile.id }) {
                all[index] = profile
            } else {
                all.append(profile)
            }
            persistLocked(all)
            return nil
        }
        return error
    }

    /// Удаляет профиль вместе с его секретами.
    public func delete(id: UUID) {
        deleteSecrets(profileID: id)
        lock.lock()
        defer { lock.unlock() }
        persistLocked(profilesLocked().filter { $0.id != id })
    }

    /// Удаляет только секреты профиля (профиль остаётся).
    public func deleteSecrets(profileID: UUID) {
        if let password = password(profileID: profileID) { SecretRedactor.unregister(password) }
        if let passphrase = passphrase(profileID: profileID) {
            SecretRedactor.unregister(passphrase)
        }
        keychain.deleteAllSecrets(profileID: profileID)
    }

    /// Профиль для роли (С1/С2), если настроен.
    public func profile(for role: ServerRole) -> ConnectionProfile? {
        lock.lock()
        defer { lock.unlock() }
        return profilesLocked().first { $0.role == role }
    }

    // MARK: Секреты (Keychain)

    public func setPassword(_ password: String, profileID: UUID) throws {
        try keychain.setSecret(password, profileID: profileID, kind: .password)
        SecretRedactor.register(password)
    }

    public func password(profileID: UUID) -> String? {
        keychain.secret(profileID: profileID, kind: .password)
    }

    public func setPassphrase(_ passphrase: String, profileID: UUID) throws {
        try keychain.setSecret(passphrase, profileID: profileID, kind: .passphrase)
        SecretRedactor.register(passphrase)
    }

    public func passphrase(profileID: UUID) -> String? {
        keychain.secret(profileID: profileID, kind: .passphrase)
    }

    public func hasSecret(profileID: UUID, kind: KeychainStore.SecretKind) -> Bool {
        keychain.hasSecret(profileID: profileID, kind: kind)
    }

    /// Готов ли профиль к подключению: валиден и секрет аутентификации на месте.
    public func isReady(_ profile: ConnectionProfile) -> Bool {
        guard profile.validate() == nil else { return false }
        switch profile.authKind {
        case .password:
            return keychain.hasSecret(profileID: profile.id, kind: .password)
        case .key:
            if profile.keyHasPassphrase {
                return keychain.hasSecret(profileID: profile.id, kind: .passphrase)
            }
            return true
        }
    }

    // MARK: Внутреннее (вызывать только под lock)

    private func profilesLocked() -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([ConnectionProfile].self, from: data)) ?? []
    }

    private func persistLocked(_ profiles: [ConnectionProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
