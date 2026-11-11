import Foundation
import Logging

/// Реестр секретов для маскирования в журналах.
///
/// Секреты регистрируются при вводе (например, `ProfileStore.setPassword`)
/// и вырезаются из текста всех лог-сообщений: пароль, парольная фраза,
/// приватные ключи (PEM-блоки) не должны попадать в журналы (спека ssh-connections).
public enum SecretRedactor {
    private static let vault = LockedBox<Set<String>>([])
    private static let replacement = "***"

    /// Паттерн PEM-блоков приватных ключей (любой алгоритм).
    private static let privateKeyPattern =
        "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"

    /// Регистрирует секрет для маскирования. Пустые строки игнорируются.
    public static func register(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = vault.withLock { $0.insert(trimmed) }
    }

    public static func unregister(_ secret: String) {
        _ = vault.withLock { $0.remove(secret) }
    }

    public static var registeredCount: Int {
        vault.withLock { $0.count }
    }

    /// Вырезает зарегистрированные секреты и PEM-блоки ключей из текста.
    public static func redact(_ text: String) -> String {
        var result = text
        for secret in vault.withLock({ Array($0) }) {
            if result.contains(secret) {
                result = result.replacingOccurrences(of: secret, with: replacement)
            }
        }
        if let regex = try? NSRegularExpression(pattern: privateKeyPattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED:private key]")
        }
        return result
    }
}

/// LogHandler-обёртка: прогоняет сообщение и метаданные через `SecretRedactor`.
public struct SanitizingLogHandler: LogHandler {
    var underlying: LogHandler

    public var logLevel: Logging.Logger.Level {
        get { underlying.logLevel }
        set { underlying.logLevel = newValue }
    }

    public var metadata: Logging.Logger.Metadata {
        get { underlying.metadata }
        set { underlying.metadata = newValue }
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { underlying.metadata[key] }
        set { underlying.metadata[key] = newValue }
    }

    init(underlying: LogHandler) {
        self.underlying = underlying
    }

    public func log(event: LogEvent) {
        let redacted = SecretRedactor.redact("\(event.message)")
        let redactedMetadata = event.metadata?.mapValues { value in
            Logging.Logger.Metadata.Value(stringLiteral: SecretRedactor.redact("\(value)"))
        }
        underlying.log(event: LogEvent(
            level: event.level,
            message: Logging.Logger.Message(stringLiteral: redacted),
            error: event.error,
            metadata: redactedMetadata,
            source: event.source,
            file: event.file,
            function: event.function,
            line: event.line
        ))
    }
}

public extension Logger {
    /// Заменяет стандартный bootstrap всего приложения на санитизированный.
    static func bootstrapSanitized() {
        LoggingSystem.bootstrap { label in
            SanitizingLogHandler(underlying: StreamLogHandler.standardOutput(label: label))
        }
    }
}
