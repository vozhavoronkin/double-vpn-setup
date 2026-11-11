import Foundation

/// Профиль SSH-подключения к серверу цепочки.
///
/// Содержит только несекретные данные; секреты (пароль, парольная фраза ключа)
/// живут в Keychain (`KeychainStore`), на что указывают флаги ниже.
public struct ConnectionProfile: Identifiable, Codable, Sendable, Equatable {
    public enum AuthKind: String, Codable, Sendable {
        case password
        case key
    }

    public var id: UUID
    public var role: ServerRole
    public var host: String
    public var port: Int
    public var user: String
    public var authKind: AuthKind
    /// Путь к файлу приватного ключа (для `.key`).
    public var keyPath: String?
    /// Есть ли парольная фраза у ключа (сам секрет — в Keychain).
    public var keyHasPassphrase: Bool
    /// Ожидаемый отпечаток host key (TOFU, задача 2.3). Пусто — ещё не подтверждён.
    public var hostKeyFingerprint: String?

    public init(
        id: UUID = UUID(),
        role: ServerRole,
        host: String,
        port: Int = 22,
        user: String,
        authKind: AuthKind,
        keyPath: String? = nil,
        keyHasPassphrase: Bool = false,
        hostKeyFingerprint: String? = nil
    ) {
        self.id = id
        self.role = role
        self.host = host
        self.port = port
        self.user = user
        self.authKind = authKind
        self.keyPath = keyPath
        self.keyHasPassphrase = keyHasPassphrase
        self.hostKeyFingerprint = hostKeyFingerprint
    }

    // MARK: Валидация (спека ssh-connections)

    public enum ValidationError: Error, Equatable {
        case hostEmpty
        case portOutOfRange
        case userEmpty
        case keyPathMissing
        case passwordNotSet
    }

    /// Профиль готов к использованию (секреты могут быть недоступны — проверяется отдельно).
    public func validate() -> ValidationError? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return .hostEmpty }
        if port < 1 || port > 65_535 { return .portOutOfRange }
        if user.trimmingCharacters(in: .whitespaces).isEmpty { return .userEmpty }
        if authKind == .key && (keyPath ?? "").isEmpty { return .keyPathMissing }
        return nil
    }
}
