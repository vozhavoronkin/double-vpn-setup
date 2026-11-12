# Proposal

## Why

Тест-сьют `LogSanitizationTests` один раз упал и не воспроизводится 20+
прогонов (issue #3). CI-проверка `test` обязательна для мержа — флейк
маскирует реальные падения. Причина найдена анализом кода: гонка сьютов
за глобальным `SecretRedactor` (утёкшие из `ProfileStoreTests` секреты,
включая короткий `"p"` в окне теста удаления, искажают ассерты на
`redact()`).

## What Changes

- Устранить утечки глобального состояния: тесты `ProfileStoreTests`,
  регистрирующие секреты через `setPassword`, обязаны их снимать
  (`store.delete` / unregister).
- Детерминизм: `LogSanitizationTests` и `ProfileStoreTests` — единственные
  сьюты, трогающие глобальный `SecretRedactor` и Keychain — вкладываются
  в общий `@Suite(.serialized)`-контейнер (Swift Testing гоняет сьюты
  параллельно).
- Починить «пустой» тест `metadataValuesAreMasked`: `CaptureHandler`
  захватывает metadata, тест реально проверяет маскирование
  (сейчас ассерт проходит всегда, сквозное маскирование метаданных
  не тестируется).
- Исправить выявленный при этом дефект: `SanitizingLogHandler` маскирует
  только call-site metadata, а metadata уровня логгера (`logger[metadataKey:]`)
  уходит в вывод сырой. Это нарушает требование спеки `ssh-connections`
  (секреты не попадают в журналы); фикс — в рамках соответствия спеке,
  delta-спек не нужен.

## Capabilities

### New Capabilities
- Нет — изменение чисто тестовое, поведение системы не меняется.
  В `.openspec.yaml` выставлен `skip_specs: true`.

### Modified Capabilities
- Нет.

## Impact

- Тесты: `Tests/VPNChainCoreTests/LogSanitizationTests.swift`,
  `ProfileStoreTests.swift`, новый `SharedSecretStateTests.swift`;
  количество тестов не меняется (146).
- Продакшн: `Sources/VPNChainCore/Logging/SanitizingLogHandler.swift` —
  маскирование metadata уровня логгера (исправление до соответствия
  существующей спеке `ssh-connections`).
- Идентификаторы тестов получат префикс общего контейнера (влияет на
  вывод отчётов; `swift test --filter LogSanitizationTests` продолжает
  работать).
- Критерии issue #3: причина описана в PR, 20 подряд зелёных прогонов
  сьюта, весь `swift test` без флейков.
