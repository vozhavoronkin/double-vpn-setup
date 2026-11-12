# Design

## Context

Мотивация — в `proposal.md`, требования — в `specs/app-interface/spec.md`. Здесь только то,
что определяет реализацию.

Текущее состояние: MVVM-приложение SwiftUI (macOS 13+), core-логика в SPM-пакете `VPNChainCore`
покрыта 146 unit-тестами, экраны — `Sources/VPNChainSetup/Views/*`. Сейчас каждый экран
самостоятельно верстает `GroupBox` + `Grid`, контент зажат в `frame(maxWidth: 560)`, статусы
показаны цветным текстом, лог — шрифтом 11 pt, общих компонентов и accessibility-подписей нет.

Ограничения:

- deployment target macOS 13 — недоступны `ContentUnavailableView`, `.inspector`,
  `.labelIcon`/`.titleAndIcon` и прочие macOS 14+ API;
- Swift 6 strict concurrency — все UI-типы `@MainActor`-изолированы;
- `VPNChainSetup.xcodeproj` генерируется xcodegen и не хранится в git: после добавления файлов
  и ассетов обязателен `xcodegen generate`;
- тексты ошибок и условия доступности действий уже реализованы (`UserMessages`, `canStart`,
  `readinessHint`) — переработка не должна их дублировать или менять.

## Goals / Non-Goals

**Goals:**

- Один набор компонентов на все экраны; расхождения между экранами объясняются данными, а не вёрсткой.
- Состояние цепочки читается за секунды: вердикт → схема звеньев → метрики → детали проверок.
- Адаптивность 820 pt … широкий экран без горизонтального скролла и пустых полос.
- Полная работа с клавиатуры и корректный VoiceOver-обход при сохранении текущей логики.
- Ноль изменений в поведении: те же SSH-вызовы, те же тексты ошибок, те же проверки.

**Non-Goals:**

- Новые функции, настройки темы, локализация.
- Переписывание ViewModel'ей, core-типов и их тестов.
- Кастомный chrome окна, нотаризация, App Store.

## Decisions

### D1. Один файл дизайн-системы

`Sources/VPNChainSetup/Views/DesignSystem.swift`: токены отступов (4/8/12/16/24) и радиусов (6/10),
а также компоненты `Card`, `StatusPill`, `MetricRow`, `Banner`, `EmptyState`, `PageScaffold`,
`IconBadge`.

- Поверхности — `Color(nsColor: .controlBackgroundColor)` и `.quaternary`-границы; текст —
  `.primary`/`.secondary` и системные текстовые стили; акцент — системный accent color.
- Статусные цвета (`green`/`orange`/`red`) — только в иконках и пилюлях, не как цвет основного текста:
  так они читаются в тёмной теме и при Increase Contrast.
- *Альтернатива:* отдельный SPM-таргет `VPNChainUI` — избыточно для одного приложения, усложняет
  сборку и тестирование без выгоды. *Альтернатива:* оставить `GroupBox` — даёт системный вид,
  но не позволяет показать статус в заголовке карточки, поэтому заменяется своим `Card`.

### D2. Оболочка и кросс-экранные команды

`AppRootView` остаётся на `NavigationSplitView`, но sidebar получает `.listStyle(.sidebar)`,
группу «Цепочка» и `@SceneStorage` для выбранного раздела. `VPNChainApp`: стартовый размер
1040×700, минимум 820×560, `.windowToolbarStyle(.unified)`, `CommandMenu("Цепочка")`.

Команды меню действуют в любом разделе, поэтому вместо `@FocusedValue` на пять экранов вводится
`@MainActor final class AppCommandRouter: ObservableObject` в `AppServices`:

```swift
enum AppCommand { case refreshStatus, startInstall, runDiagnostics, toggleSidebar }
@Published var pending: AppCommand?
```

`AppRootView` реагирует на `pending` переключением раздела и передаёт команду экрану-получателю,
который потребляет её и сбрасывает в `nil`. Это одно состояние вместо пяти focus-binding'ов
и работает независимо от того, где находится фокус.

*Альтернатива:* `NotificationCenter` — не требует владения объектом, но невидим для компилятора
и хуже тестируется. *Альтернатива:* пункты меню только через `.focusedSceneValue` — не сработают,
когда фокус в sidebar/toolbar.

### D3. «Подключения»: адаптивная сетка карточек

`LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16)])` — две колонки на широком окне,
одна на узком. Внутри карточки поля идут стопкой «подпись `caption` → контрол на всю ширину»,
аутентификация — `Picker(.segmented)`, порт — в `DisclosureGroup("Дополнительно")`.

- *Альтернатива:* `Form`/`.formStyle(.grouped)` — на macOS 13 выглядит как инспектор и плохо
  раскладывается в две колонки. *Альтернатива:* сохранить `Grid` с подписями справа — именно
  это и создаёт «вид анкеты», который перерабатываем.
- Состояние пилюли выводится из новых computed-свойств `ConnectionsViewModel`
  (`isConfigured(_:)`, `status(for:)`), а не из новых `@Published`-полей.
- `@State` формы остаётся в существующем виде: `Binding` поверх `setForm`/`form` не меняется,
  чтобы не трогать логику сохранения секретов.

### D4. «Статус»: вердикт + схема + метрики

`StatusViewModel.overallHealth` — computed из доступности серверов и `checkResults`:
`notChecked / ok / attention / offline`. Вердикт показывается в hero-карточке вместе
с `lastUpdatedAt`.

Схема звеньев — `HStack` из четырёх `IconBadge`, соединённых `Rectangle().fill(.quaternary)`;
цвет узла — по состоянию звена, подписи переносятся при сжатии.

- *Альтернатива:* `Canvas`/граф — избыточно, ломает VoiceOver и не даёт выигрыша в читаемости.
- Метрики — `MetricRow` с иконкой состояния; тексты и различие «нет связи» / «сломано» берутся
  из существующей модели без изменений.
- Ручной чек-лист — свёрнутый `DisclosureGroup`, чтобы не конкурировать с проверками за внимание.

### D5. «Установка»: прогресс и таймлайн

`InstallViewModel.progressFraction`/`completedCount` — computed из существующего `steps`.
Шаги рисуются таймлайном: `VStack` с вертикальной линией-оверлеем, статус шага — через `StatusPill`.
Анимация «выполняется» включается только при `!accessibilityReduceMotion`.

Журнал — `Card` с `Text(...).font(.system(.caption, design: .monospaced))`, автоскролл
(существующий `ScrollViewReader`) и кнопка «Скопировать» (`NSPasteboard`).

- *Копирование и секреты:* в буфер попадает уже санитизированный журнал — тот же массив
  `logLines`, что показан на экране; отдельного пути утечки не появляется.

### D6. «Диагностика» и «Клиент»

Диагностика: карточка симптома (menu-picker на всю ширину + пояснение + primary-кнопка), сводка
результатов «N из M», советы — нумерованные кружки. Uninstall — отдельная карточка с destructive-
акцентом; кнопки остаются `.bordered`/`.borderedProminent` с `tint(.red)` (заливка красным
на всю кнопку плохо читается в тёмной теме), подтверждение — существующий `confirmationDialog`
с `Button(role: .cancel)`.

«Клиент»: шаги — нумерованные бейджи, без имитации интерактивных контролов; тексты шагов
переносятся из текущего кода без изменений.

### D7. ViewModel'и: только вычисляемые свойства

Добавляются: `ConnectionsViewModel.isConfigured(_:)`, `status(for:)`, `hasStoredSecret(_:kind:)`;
`StatusViewModel.overallHealth`, `lastUpdatedAt`, `passedCount`, `failedCount`;
`InstallViewModel.progressFraction`, `completedCount`, `copyLogToPasteboard()`;
`DiagnosticsViewModel.passedCount`, `totalCount`. Новых сетевых вызовов нет, контракты
`@Published`-полей сохраняются — тесты не меняются.

### D8. Доступность как часть компонентов, а не доработка

`accessibilityLabel` и `.help` задаются в `IconBadge`/иконочных кнопках на месте использования;
`Card` группирует содержимое через `accessibilityElement(children: .contain)` с заголовком;
схема звеньев получает составную подпись («Сервер-вход: активен»). Default action — на кнопках
primary-действий (`keyboardShortcut(.defaultAction)`), Esc — на отмене диалогов.

### D9. Иконка приложения

1024×1024 PNG (тёмно-синий градиент, мотив «звено цепи + щит», без текста — читается в 16 pt),
нарезается `sips` в `Sources/VPNChainSetup/Resources/Assets.xcassets/AppIcon.appiconset`
(16/32/64/128/256/512 с @1x/@2x) с `Contents.json`. В `project.yml` добавляется
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; каталог попадает в target через существующий
`sources: path: Sources/VPNChainSetup`.

### D10. Проверка

`swift build` (компилирует и executable-таргет), `swift test` (146 тестов без изменений),
`xcodegen generate`, `xcodebuild -project VPNChainSetup.xcodeproj -scheme VPNChainSetup
-destination 'platform=macOS' build`, ручной прогон в light/dark, на узком и максимизированном
окне, только с клавиатуры, `openspec validate redesign-app-ui --strict`.

## Risks / Trade-offs

- macOS 13 не имеет `ContentUnavailableView` → собственный `EmptyState` (≈10 строк) вместо повышения
  deployment target.
- Свои карточки вместо `GroupBox` теряют бесплатную системную вибрацию → компенсируется
  `controlBackgroundColor` + hairline-границей, которые корректно выглядят в обеих темах.
- Статусные `green`/`red` в тексте плохо читаются на тёмном фоне → статусные цвета только
  в иконках/пилюлях, текст остаётся семантическим.
- Две колонки не влезают при 820 pt → `GridItem(.adaptive(minimum: 360))` сам схлопывается
  в одну колонку, отдельный breakpoint не нужен.
- Роутер команд добавляет одно общее состояние → «залипшая» команда исключается сбросом в `nil`
  сразу после потребления и проверкой `pending` в `onChange`.
- Иконка генерируется скриптом → шаг детерминирован и не требует сети; при отсутствии каталога
  сборка не ломается, приложение просто использует стандартную иконку.

## Migration Plan

Изменение чисто презентационное, миграция данных не нужна. Порядок:

1. Дизайн-система и компоненты.
2. Оболочка (`VPNChainApp`, `AppRootView`) — после неё экраны можно переводить по одному.
3. Экраны по одному, каждый коммит оставляет приложение собираемым.
4. Иконка и `project.yml`, затем обязательный `xcodegen generate`.
5. Откат — обычный revert коммитов: пользовательские данные (профили в UserDefaults, секреты
   в Keychain, состояние на серверах) не затрагиваются.
