import Foundation

/// Сведения об окружении сервера (ОС/архитектура), полученные при проверке соединения.
public struct ServerEnvironment: Sendable, Equatable {
    /// Имя дистрибутива из /etc/os-release, например «Ubuntu».
    public let osName: String
    /// Версия из VERSION_ID, например «22.04».
    public let osVersion: String?
    /// Архитектура из `uname -m`: x86_64 / aarch64.
    public let architecture: String

    public init(osName: String, osVersion: String?, architecture: String) {
        self.osName = osName
        self.osVersion = osVersion
        self.architecture = architecture
    }

    /// Компактное представление для UI: «Ubuntu 22.04, x86_64».
    public var displayText: String {
        let osPart = osVersion.map { "\(osName) \($0)" } ?? osName
        return "\(osPart), \(architecture)"
    }
}

/// Парсер `/etc/os-release` (задача 2.3, покрывается unit-тестами на фиксчунах).
public enum OSReleaseParser {
    /// Возвращает (NAME, VERSION_ID) из содержимого os-release.
    public static func parse(_ content: String) -> (name: String, version: String?) {
        var name: String?
        var version: String?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(
                in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "NAME": name = value
            case "VERSION_ID": version = value
            default: break
            }
        }
        return (name: name ?? "Unknown", version: version)
    }
}

/// Проверка соединения с сервером: контрольная команда + отчёт ОС/архитектуры.
///
/// Реализует требования спеки `ssh-connections`: проверка до начала операций,
/// TOFU-подтверждение host key с сохранением отпечатка в профиле.
public struct ConnectionChecker: Sendable {
    public enum CheckError: Error, Equatable {
        case profileInvalid(String)
        case secretMissing(String)
        case hostKeyChanged
    }

    private let store: ProfileStore
    /// Замыкание UI-подтверждения неизвестного отпечатка (TOFU).
    /// Возвращает true, если пользователь принял отпечаток.
    private let confirmUnknownFingerprint: @Sendable (String, String) async -> Bool

    public init(
        store: ProfileStore,
        confirmUnknownFingerprint: @escaping @Sendable (String, String) async -> Bool = {
            _, _ in true
        }
    ) {
        self.store = store
        self.confirmUnknownFingerprint = confirmUnknownFingerprint
    }

    /// Составляет опции подключения из профиля и его секретов.
    public func connectOptions(for profile: ConnectionProfile) throws -> SSHConnectOptions {
        if let validation = profile.validate() {
            throw CheckError.profileInvalid("\(validation)")
        }
        let auth: SSHAuthMethod
        switch profile.authKind {
        case .password:
            guard let password = store.password(profileID: profile.id) else {
                throw CheckError.secretMissing("пароль не задан для \(profile.host)")
            }
            auth = .password(password)
        case .key:
            guard let keyPath = profile.keyPath, !keyPath.isEmpty else {
                throw CheckError.profileInvalid("keyPathMissing")
            }
            let keyData = try Data(contentsOf: URL(fileURLWithPath: keyPath))
            let passphrase = store.passphrase(profileID: profile.id)
            let material = try OpenSSHPrivateKeyFile.load(from: keyData, passphrase: passphrase)
            auth = .key(material)
        }
        let fingerprint = profile.hostKeyFingerprint
        let policy = SSHHostKeyPolicy.tofu(expectedFingerprint: fingerprint) {
            [confirmUnknownFingerprint, host = profile.host] candidate in
            await confirmUnknownFingerprint(host, candidate)
        }
        return SSHConnectOptions(
            host: profile.host,
            port: profile.port,
            user: profile.user,
            auth: auth,
            hostKeyPolicy: policy
        )
    }

    /// Полная проверка: подключение + контрольная команда + окружение.
    /// При успехе фиксирует отпечаток в профиле (TOFU-запись).
    @discardableResult
    public func check(_ profile: ConnectionProfile) async throws -> ServerEnvironment {
        let options = try connectOptions(for: profile)
        let client = SSHClient(options: options)
        do {
            try await client.connect()
            // Контрольная команда: os-release может отсутствовать (мягкий сбой), uname обязателен.
            let probe = """
                cat /etc/os-release 2>/dev/null; echo "---VPNCHAIN---"; uname -m
                """
            let result = try await client.run(probe, timeout: 20)
            guard result.succeeded else {
                throw SSHError.connectionFailed(
                    "контрольная команда вернула код \(result.exitCode ?? -1)")
            }
            let parts = result.stdout.components(separatedBy: "---VPNCHAIN---")
            let osRelease = parts.first ?? ""
            let arch =
                parts.dropFirst().first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? ""
            guard !arch.isEmpty else {
                throw SSHError.connectionFailed("не удалось определить архитектуру (uname -m)")
            }
            let parsed = OSReleaseParser.parse(osRelease)
            let environment = ServerEnvironment(
                osName: parsed.name,
                osVersion: parsed.version,
                architecture: arch
            )

            // TOFU: сохраняем отпечаток, если он ещё не был записан.
            if let seen = client.seenHostKeyFingerprint, profile.hostKeyFingerprint != seen {
                var updated = profile
                updated.hostKeyFingerprint = seen
                store.upsert(updated)
            }
            await client.close()
            return environment
        } catch let error as SSHError {
            await client.close()
            if case .hostKeyRejected = error {
                throw CheckError.hostKeyChanged
            }
            throw error
        } catch {
            await client.close()
            throw error
        }
    }
}
