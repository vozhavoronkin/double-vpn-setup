# Design

## Решения

- Инструмент: swift-format из тулчейна Xcode через `xcrun swift-format`
  (локально 6.4.4; на macos-15 раннере — из дефолтного Xcode). Не
  Homebrew/mint: ноль зависимостей, версия определяется Xcode. Обновление
  Xcode может подтянуть новые правила дефолтного набора — принимаем.
- Конфиг `.swift-format`: плоская схема этой версии (проверена
  `xcrun swift-format dump-configuration`), без обёртки `formatter`:
  `version: 1`, `indentation: { spaces: 4 }`, `lineLength: 100`.
  Правила — дефолтные, кроме трёх отключённых (см. ниже).
  Импорты: опция `orderedImports` и правило `OrderedImports` в этой
  версии включены по умолчанию — порядок импортов проверяется и
  исправляется автоматически.
- Отключённые правила (семантические, не форматные; конфликтуют с
  намеренным идиоматичным кодом, форматтер их не исправляет):
  - `OnlyOneTrailingClosureArgument` — multi-closure API
    (`Card(accessory:content:)`, SSHClient.withTimeout(seconds:onTimeout:));
  - `AlwaysUseLowerCamelCase` — платформенные имена (`x86_64`);
  - `UseSynthesizedInitializer` — осознанные явные инициализаторы
    (`SSHModels`).
  `EndOfLineComment` оставлено включённым: 4 длинных end-of-line
  комментария в тестах перенесены на строку выше и вошли в коммит
  реформата.
- CI: отдельный job `lint` (macos-15) с checkout и
  `xcrun swift-format lint --strict -r -p Sources Tests Package.swift`,
  параллельно с `test`. Отдельный статус нагляднее, чем шаг внутри
  тестового job. Проверено локально: на чистом дереве exit 0, при
  нарушении — exit 1.
- Порядок коммитов в PR (CI зелёный на каждом коммите):
  1. Механический реформат: `xcrun swift-format format -i -r Sources Tests
     Package.swift` (конфиг подхватывается из корня автоматически; при
     необходимости — `--configuration .swift-format`) — коммит содержит
     только код; `swift test` зелёный; `xcodegen generate` не нужен (набор
     файлов не меняется).
  2. Инфраструктурный: `.swift-format`, job `lint` в ci.yml, обновление
     AGENTS.md, артефакты OpenSpec-изменения.

  После обоих коммитов прогон `lint --strict` даёт ноль диагностик.
- Команды в AGENTS.md («Команды»):
  - `xcrun swift-format format -i -r Sources Tests Package.swift`
  - `xcrun swift-format lint --strict -r -p Sources Tests Package.swift`
    (та же проверка, что в CI)

## Верификация авто-дискавери конфига

Проверено: `swift-format` находит `.swift-format` в корне репозитория
автоматически (проба с отступом 4 и сортировкой импортов форматируется
конфигом без флага `--configuration`). Флаг остаётся запасным вариантом,
если версия тулчейна изменит поведение.

## Риски

- ~486 строк длиннее 120 и ~1025 длиннее 100 символов → реформат-коммит
  большой, но механический; ревью с ignore-whitespace.
- Длинные строковые литералы (шаблоны конфигов, systemd-юниты, русские
  тексты UI) форматтер не переносит; если lint ругается — вынести в
  константы/многострочные литералы без изменения содержимого.

## Out of scope

- SwiftLint и семантические правила (opt-in force-try и т.п.).
- `scripts/make-app-icon.swift`.
- git hooks / pre-commit.
