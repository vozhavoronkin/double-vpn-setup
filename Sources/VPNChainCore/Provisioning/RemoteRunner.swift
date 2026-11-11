import Foundation

/// Транспорт выполнения удалённых команд. Абстракция над SSHClient:
/// позволяет движку provisioning и детекторам работать с фейковым раннером в тестах.
public protocol RemoteRunner: Sendable {
    func run(
        _ command: String,
        timeout: TimeInterval?,
        onOutput: (@Sendable (SSHOutputChunk) -> Void)?
    ) async throws -> SSHExecResult
}

extension SSHClient: RemoteRunner {}

/// Ошибки шагов provisioning.
public enum ProvisioningError: Error, Equatable {
    /// Docker не установлен или не отвечает.
    case dockerMissing(String)
    /// Контейнер AmneziaWG не найден (спека: «сначала установите AmneziaWG из приложения AmneziaVPN»).
    case containerMissing
    /// Неподдерживаемая ОС/архитектура.
    case unsupportedPlatform(String)
    /// Не удалось разобрать вывод команды.
    case parseFailed(String)
    /// Команда шага завершилась с ошибкой.
    case commandFailed(step: String, exitCode: Int?, stderr: String)
}
