import Logging

/// Центральные логгеры приложения. Все записи проходят через SanitizingLogHandler (задача 2.4),
/// который маскирует пароли, парольные фразы и приватные ключи.
public enum Log {
    /// Базовый логгер приложения и операций с серверами.
    public static let app: Logger = Logger(label: "ru.vpnchain.app")
}
