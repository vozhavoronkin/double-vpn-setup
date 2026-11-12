import Testing

/// Общий контейнер для сьют, делящих глобальное состояние `SecretRedactor`
/// и macOS Keychain. Swift Testing выполняет сьюты параллельно, поэтому
/// `.serialized` здесь сериализует всё поддерево: тесты этих сьют не
/// пересекаются по времени и не искажают друг другу ассерты на глобальном
/// состоянии.
///
/// Сами тесты объявлены в расширениях в файлах соответствующих сьют
/// (`LogSanitizationTests.swift`, `ProfileStoreTests.swift`).
@Suite(.serialized)
struct SharedSecretStateTests {
    @Suite struct LogSanitizationTests {}
    @Suite struct ProfileStoreTests {}
}
