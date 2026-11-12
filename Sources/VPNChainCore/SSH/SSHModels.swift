import Crypto
import Foundation
import NIOSSH

/// Способ аутентификации на сервере (пароль или приватный ключ).
public enum SSHAuthMethod: Sendable {
    case password(String)
    case key(SSHKeyMaterial)
}

/// Готовый к использованию приватный ключ SSH (NIOSSHPrivateKey обёрнут в Sendable-тип).
public struct SSHKeyMaterial: Sendable {
    /// Тип ключа из OpenSSH-файла, например `ssh-ed25519`.
    public let algorithm: String
    /// Комментарий ключа (если был в файле).
    public let comment: String?
    /// Публичный ключ в виде строки OpenSSH (`algorithm base64`), если выводим.
    public let publicKeyOpenSSH: String?
    let privateKey: NIOSSHPrivateKey

    init(
        algorithm: String, comment: String?, publicKeyOpenSSH: String?, privateKey: NIOSSHPrivateKey
    ) {
        self.algorithm = algorithm
        self.comment = comment
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.privateKey = privateKey
    }
}

/// Ошибки SSH-транспорта.
public enum SSHError: Error, Equatable {
    case connectionFailed(String)
    case authFailed(String)
    case hostKeyRejected
    case timeout(String)
    case closedUnexpectedly(String)
    case unsupportedKey(String)
    case keyParsing(String)
    case wrongPassphrase
    case cancelled
}

/// Политики проверки host key сервера.
public enum SSHHostKeyPolicy: Sendable {
    /// TOFU: отпечаток сравнивается с ожидаемым; если ожидаемого нет —
    /// решение принимает замыкание (UI-подтверждение в задаче 2.3).
    case tofu(expectedFingerprint: String?, confirm: @Sendable (String) async -> Bool)
    /// Отклонять любые неизвестные отпечатки (кроме совпадающих с ожидаемым).
    case pinned(expectedFingerprint: String)
    /// Принимать всё. Только для тестов.
    case acceptAll
}

/// Параметры подключения к серверу.
public struct SSHConnectOptions: Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var auth: SSHAuthMethod
    public var hostKeyPolicy: SSHHostKeyPolicy
    /// Таймаут установления TCP-соединения, секунды.
    public var connectTimeout: TimeInterval
    /// Таймаут исполнения одной команды по умолчанию, секунды.
    public var commandTimeout: TimeInterval

    public init(
        host: String,
        port: Int = 22,
        user: String,
        auth: SSHAuthMethod,
        hostKeyPolicy: SSHHostKeyPolicy = .acceptAll,
        connectTimeout: TimeInterval = 15,
        commandTimeout: TimeInterval = 120
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.hostKeyPolicy = hostKeyPolicy
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
    }
}

/// Итог выполнения удалённой команды.
public struct SSHExecResult: Sendable, Equatable {
    public var exitCode: Int?
    public var stdout: String
    public var stderr: String
    /// Сигнал, которым завершился процесс (если был), например `KILL`.
    public var exitSignal: String?

    public init(exitCode: Int?, stdout: String, stderr: String, exitSignal: String? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.exitSignal = exitSignal
    }

    /// Команда завершилась успешно (код возврата 0).
    public var succeeded: Bool { exitCode == 0 }
}

/// Кусок вывода удалённой команды для потоковой передачи в UI.
public enum SSHOutputChunk: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
}
