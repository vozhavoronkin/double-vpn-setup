# Tasks

## 1. Доказательство механизма (до фикса)
- [x] 1.1 Временный тест-проба: зарегистрировать `"p"` и выполнить ассерты
      `profileStoreRegistersSecretsForRedaction` — убедиться, что падают
      (`before.contains` и финальный `!contains("***")`); вывод зафиксировать
      для PR-описания.
- [x] 1.2 Удалить пробу.

## 2. Устранение утечек глобального состояния
- [x] 2.1 `ProfileStoreTests.passwordGoesToKeychainAndNotToUserDefaults`:
      cleanup профиля/секрета (defer `store.delete`).
- [x] 2.2 `ProfileStoreTests.readinessRequiresSecret`: cleanup профиля/секрета.

## 3. Детерминизм
- [x] 3.1 Общий `@Suite(.serialized)`-контейнер `SharedSecretStateTests`,
      вложить `LogSanitizationTests` и `ProfileStoreTests`; проверить,
      что `swift test --filter LogSanitizationTests` находит тесты.

## 4. metadataValuesAreMasked
- [x] 4.1 `CaptureHandler` захватывает metadata (рядом с message, под
      LockedBox); тест ассертит: `metadata["password"]` содержит `"***"`,
      не содержит сырой секрет; ассерт по сообщению сохранён.
- [x] 4.2 `SanitizingLogHandler`: маскировать metadata уровня логгера —
      объединить `self.metadata` с `event.metadata` (call-site приоритетнее)
      и прогнать все значения через `SecretRedactor.redact`.

## 5. Верификация и оформление
- [x] 5.1 `swift test`: все 146 тестов зелёные; форматирование
      `xcrun swift-format lint --strict` — ноль диагностик.
- [x] 5.2 20 подряд зелёных прогонов
      `swift test --filter LogSanitizationTests`.
- [x] 5.3 Полный `swift test` — 3 прогона подряд без флейков.
- [x] 5.4 Причина флейка описана в PR (ссылка на анализ из design.md).

## 6. Замечания ревью PR #14
- [x] 6.1 `profileStoreRegistersSecretsForRedaction`: `defer store.delete` —
      при throw из `setPassword` секрет не остаётся в глобальном редокторе.
- [x] 6.2 Рекурсивная санитизация составных metadata (array/dictionary);
      `.stringConvertible` задокументирован как `.string`-конверсия.
- [x] 6.3 Заведён issue #15 на инъекцию `SecretRedactor` (корневая причина).
