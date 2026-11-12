import Foundation
import Logging
import Testing

@testable import VPNChainCore

/// Ловушка лог-сообщений для проверки санитизации.
private final class CaptureHandler: LogHandler, @unchecked Sendable {
    private let box: LockedBox<[(level: Logger.Level, message: String, metadata: Logger.Metadata?)]>
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    init() {
        self.box = LockedBox([])
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        box.withLock { $0.append((event.level, "\(event.message)", event.metadata)) }
    }

    var captured: [(level: Logger.Level, message: String, metadata: Logger.Metadata?)] {
        box.withLock { $0 }
    }
}

/// Тесты задачи 2.4: секреты не попадают в журнал.
/// Вложена в сериализованный `SharedSecretStateTests`: `SecretRedactor` —
/// глобальное состояние, общее с `ProfileStoreTests`.
extension SharedSecretStateTests.LogSanitizationTests {
    private func makeLogger() -> (Logger, CaptureHandler) {
        let capture = CaptureHandler()
        let logger = Logger(label: "test") { _ in SanitizingLogHandler(underlying: capture) }
        return (logger, capture)
    }

    @Test func registeredSecretIsMasked() {
        let (logger, capture) = makeLogger()
        let secret = "супер-секрет-778"
        SecretRedactor.register(secret)
        defer { SecretRedactor.unregister(secret) }

        logger.info("Подключение с паролем \(secret) выполнено")
        let message = capture.captured.first?.message ?? ""
        #expect(!message.contains(secret))
        #expect(message.contains("***"))
    }

    @Test func pemPrivateKeyBlockIsMasked() {
        let (logger, capture) = makeLogger()
        let pem = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB
            -----END OPENSSH PRIVATE KEY-----
            """
        logger.warning("конфиг: \(pem)")
        let message = capture.captured.first?.message ?? ""
        #expect(!message.contains("b3BlbnNzaC1rZXktdjE"))
        #expect(message.contains("[REDACTED:private key]"))
    }

    @Test func ordinaryTextIsUntouched() {
        let (logger, capture) = makeLogger()
        logger.info("handshake ok, порт 51828/UDP")
        #expect(capture.captured.first?.message == "handshake ok, порт 51828/UDP")
    }

    @Test func metadataValuesAreMasked() {
        let (logger, capture) = makeLogger()
        let secret = "metadata-secret-555"
        SecretRedactor.register(secret)
        defer { SecretRedactor.unregister(secret) }

        // Metadata уровня логгера (logger[metadataKey:]).
        var loggerWithMeta = logger
        loggerWithMeta[metadataKey: "password"] = .string(secret)
        loggerWithMeta.info("аутентификация")

        // Call-site metadata.
        logger.info("подключение", metadata: ["password": .string(secret)])

        let captured = capture.captured
        #expect(captured.count == 2)
        for event in captured {
            let passwordValue = event.metadata?["password"].map { "\($0)" } ?? ""
            #expect(!passwordValue.contains(secret), "Секрет утёк в metadata: \(passwordValue)")
            #expect(passwordValue.contains("***"))
        }
        #expect(captured.first?.message == "аутентификация")
        #expect(captured.last?.message == "подключение")
    }

    @Test func profileStoreRegistersSecretsForRedaction() throws {
        let suiteName = "vpnchain-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ProfileStore(
            defaults: defaults, keychain: KeychainStore(service: "ru.vpnchain.tests"))
        let profile = ConnectionProfile(role: .entry, host: "h", user: "root", authKind: .password)

        let secret = "leaked-password-9"
        let before = SecretRedactor.redact("текст \(secret) конец")
        try store.setPassword(secret, profileID: profile.id)
        #expect(before.contains(secret))
        #expect(SecretRedactor.redact("текст \(secret) конец").contains("***"))

        store.delete(id: profile.id)
        #expect(!SecretRedactor.redact("текст \(secret) конец").contains("***"))
    }
}
