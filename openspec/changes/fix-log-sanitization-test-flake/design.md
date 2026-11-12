# Design

## Причина (установлена анализом кода, проверена моделью редактирования)

1. `SecretRedactor.vault` — глобальное mutable-состояние (LockedBox),
   сьюты Swift Testing выполняются параллельно.
2. `ProfileStoreTests` регистрирует секреты глобально через
   `ProfileStore.setPassword`:
   - `"s3cr3t-пароль-42"` — утечка навсегда (нет cleanup);
   - `"x"` — утечка навсегда;
   - `"p"` — живёт в окне `setPassword`…`store.delete` теста удаления.
3. `LogSanitizationTests.profileStoreRegistersSecretsForRedaction`
   ассертит `redact("текст leaked-password-9 конец")`: при `"p"` в
   хранилище фикстура превращается в `"leaked-***assword-9"` — падают
   `before.contains(secret)` и финальный `!contains("***")`.
4. Собственный `.serialized` сьюты сериализует только свои тесты —
   против `ProfileStoreTests` защиты нет. Редкое окно × параллельное
   планирование = разовый флейк.

## Решения

- Общий контейнер: `@Suite(.serialized) struct SharedSecretStateTests`,
  внутри вложенные `LogSanitizationTests` и `ProfileStoreTests` (обе
  сьюты — единственные потребители `SecretRedactor`/Keychain; проверено
  grep по Tests/). Трейт сериализует всё поддерево → сьюты не
  пересекаются по времени. Параллелизм остальных 17 сьют не трогаем.
- Утечки: в `passwordGoesToKeychainAndNotToUserDefaults` и
  `readinessRequiresSecret` добавить cleanup (`defer { store.delete(id: profile.id) }`)
  — глобальное хранилище не должно засоряться даже при падении ассертов.
- `metadataValuesAreMasked`: `CaptureHandler` хранит `(level, message, metadata)`
  под тем же `LockedBox`; тест проверяет оба пути — metadata уровня
  логгера (`logger[metadataKey:]`) и call-site metadata
  (`logger.info(_:metadata:)`): значение `password` содержит `"***"`
  и не содержит сырой секрет; ассерт по сообщению сохранён.
- Ассерты `profileStoreRegistersSecretsForRedaction` не переписываем:
  при сериализации они детерминированы, смысл сохраняется.
- Keychain остаётся реальным: интеграция `ProfileStore`→Keychain — то,
  что тестируется; признак упавшего прогона (содержимое `***` в ассертах)
  соответствует гонке состояния, а не ошибке Keychain.
- Форматирование — `xcrun swift-format` (конфиг уже в репо), тестовые
  файлы в области линта.

## Дефект санитизации metadata (выявлен при усилении теста)

- `Logger[metadataKey:]` кладёт значение в `handler.metadata`; в
  `LogEvent.metadata` попадает только call-site metadata
  (`Logger._log`), а `StreamLogHandler` примешивает `self.metadata`
  при форматировании — уже после санитайзера. Секрет из metadata
  уровня логгера уходил в журнал сырым (нарушение спеки
  `ssh-connections`).
- Фикс: в `SanitizingLogHandler.log(event:)` объединять `self.metadata`
  с `event.metadata` (call-site приоритетнее), прогонять все значения
  через `SecretRedactor.redact` и передавать merged-словарь как
  `event.metadata` дальше. `StreamLogHandler` применяет explicit
  metadata поверх собственной — все ключи хендлера перекрыты
  отредактированными значениями.
- Тест `metadataValuesAreMasked` покрывает оба пути и без фикса падает
  на пути уровня логгера.

## Верификация

- Механизм: до фикса — временный тест-проба, регистрирующий `"p"` и
  повторяющий ассерты фикстуры, падает; после фикса — снят.
- 20 подряд зелёных прогонов `swift test --filter LogSanitizationTests`
  (критерий issue #3; после реструктуризации фильтр по подстроке
  по-прежнему находит вложенную сьюту).
- Полный `swift test` несколько прогонов подряд — без флейков,
  146 тестов зелёные.

## Риски

- Смена идентификаторов тестов (префикс контейнера) — влияет только на
  читаемость отчётов CI.
- `.serialized` на общем контейнере слегка снижает параллелизм двух
  самых медленных сьютов с Keychain (десятки мс) — незначимо.

## Out of scope

- Изменения `SecretRedactor`, `ProfileStore`, `KeychainStore`
  (в `SanitizingLogHandler` — только фикс metadata из раздела выше).
- Перевод тестов на in-memory keychain.
- Правки CI.
