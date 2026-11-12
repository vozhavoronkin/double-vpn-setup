# AGENTS.md

## Repo status

- Нативное macOS-приложение (Swift 6, SwiftUI, macOS 13+) для автоматизации двойной VPN-цепочки
  `клиент → сервер-вход (AmneziaVPN) → сервер-выход → интернет` по SSH.
- Источник требований — `resources/vpn-chain-amneziawg-spec.md` (ТЗ). Работа ведётся через
  OpenSpec-изменение `openspec/changes/macos-vpn-chain-setup-app/` (`tasks.md` — трекер прогресса).
- IntelliJ-файлы (`.idea/`, `double-vpn-setup.iml`) — остатки исходного каркаса, они в git
  намеренно; не удалять и не добавлять в `.gitignore`.

## Команды

```bash
swift test                                  # все unit-тесты (146 шт., ~1 c)
swift test --filter NameOfTest              # один тест/сьют
swift build                                 # сборка core-модуля
xcodegen generate                           # пересоздать VPNChainSetup.xcodeproj из project.yml
xcodebuild -project VPNChainSetup.xcodeproj -scheme VPNChainSetup \
  -destination 'platform=macOS' build       # сборка приложения
xcrun swift-format format -i -r Sources Tests Package.swift   # форматирование
xcrun swift-format lint --strict -r -p Sources Tests Package.swift  # проверка (как в CI)
openspec validate macos-vpn-chain-setup-app --strict
```

- `VPNChainSetup.xcodeproj` генерируется и **не** хранится в git — после добавления/удаления
  файлов в `Sources/VPNChainSetup` запускайте `xcodegen generate`.
- Форматирование — swift-format из тулчейна Xcode (`xcrun swift-format`; swift-format не на
  PATH, поэтому только через `xcrun`), конфиг `.swift-format` в корне: ширина 100, отступ
  4 пробела. CI (job `lint`) падает на нарушениях; перед коммитом прогоняйте обе команды выше.
  Остальной стиль — `public` в core, русские doc-комментарии к нетривиальным местам.

## Архитектура

- `Package.swift` — SPM-пакет с таргетом-библиотекой `VPNChainCore` (вся логика, тестируется
  через `swift test`), приложение `VPNChainSetup` собирается только Xcode-проектом.
- `Sources/VPNChainCore/`
  - `SSH/` — клиент на swift-nio-ssh: connect (пароль/ключ), exec с таймаутом, TOFU-pinning
    host key, сборка вывода.
  - `Provisioning/` — конечный автомат установки (`ProvisioningEngine`), детект окружения
    AmneziaWG, установка ПО по пинам (`SoftwareInstall`), конфиги (`ConfigTemplates`), правила
    серверов (`ConfigureC1`/`ConfigureC2`), systemd-юниты.
  - `Diagnostics/` — декларативные проверки (`ChecksEngine`), парсеры вывода, план очистки
    (`UninstallPlan`), таблица симптомов.
  - `Secrets/`, `Storage/` — ключи/обфускация, `ChainState.Environment` (env-файл на входе),
    профили в UserDefaults, секреты в Keychain.
  - `Logging/` — санитизация логов (секреты не попадают в вывод).
- `Sources/VPNChainSetup/` — MVVM: `ViewModels/` + `Views/` (экраны подключений, установки,
  статуса, диагностики, клиента), `Views/DesignSystem.swift` — карточки, статус-пилюли,
  строки метрик, баннеры, empty state и токены отступов, `Services/AppServices.swift` — сборка
  зависимостей и `AppCommandRouter` для меню-команд (⌘R / ⌘↩ / ⌘D).
- `Sources/VPNChainSetup/Resources/Assets.xcassets` — иконка приложения (`AppIcon`), собирается
  через `ASSETCATALOG_COMPILER_APPICON_NAME` в `project.yml`; исходник рисуется
  `scripts/make-app-icon.swift` (детерминированно, без сетевых зависимостей), затем нарезается `sips`.

## Правила домена (важные, легко сломать)

- UI-терминология: «Сервер-вход» / «Сервер-выход». `С1`/`С2` — только во внутреннем коде.
  Интерфейс русский, без плейсхолдеров-примеров в полях.
- Отбор клиентского трафика на входе — по `fwmark` (mangle `PREROUTING`), **не** по `iif`:
  интерфейс контейнера используется в обоих направлениях, и `iif` ломал handshake клиентов.
  Ответы контейнера клиентам исключаются по `--sport <порт клиентского AWG>`.
- NAT: на входе — `nat POSTROUTING -o awg-relay -j RETURN` (иначе Docker SNAT'ит в `10.99.0.1`),
  на выходе — MASQUERADE для relay-подсети `10.99.0.0/24` и подсетей входа.
- Имена/интерфейсы/подсети не хардкодятся: контейнер, `amn*`-интерфейс, `CLIENT_SUBNET`,
  `CLIENT_PORT` определяются детектом и сохраняются в `/etc/amnezia/chain/env`.
- Managed systemd-юниты: `systemctl enable` + `systemctl restart` (не `--now` для активных).
- Нельзя ломать контейнер AmneziaVPN и SSH-доступ: удаление — только по явному подтверждению,
  uninstall не трогает `docker stop/rm` и не блокирует host-трафик.
- Пины версий (`AmneziaPins`) менять только осознанно: `amneziawg-go` — старая userspace-линия
  (v3.x падает на ядрах со встроенным WireGuard).

## Ветки и pull request'ы

- `main` защищена rulesets: прямой push запрещён, изменения — только через pull request (1 аппрув; владелец может мержить с bypass). Force push и удаление `main` заблокированы для всех.
- Работа — в отдельной ветке, затем PR; после мержа ветку удалить.
- Одна ветка — одна цель: фича и релизный коммит (версия, CHANGELOG) в один PR не смешиваются.

## Релиз

Релиз выходит тегом `vX.Y.Z` на `main`; пуш тега запускает `.github/workflows/release.yml` (universal-сборка, zip, `SHA256SUMS.txt`).

1. Ветка `chore/release-X.Y.Z` от актуального `main`.
2. В ней: `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION` в `project.yml` (билд-номер растёт на 1), раздел `## [X.Y.Z] — дата` в `CHANGELOG.md`, затем `xcodegen generate` и `xcodebuild … build`.
3. PR в `main`, мерж после аппрува (или bypass владельца).
4. После мержа — аннотированный тег на коммит `main`: `git tag -a vX.Y.Z origin/main -m "X.Y.Z — …"`, затем `git push origin vX.Y.Z`. Тег ставится только на смерженный коммит в `main`.
5. Ветка `release/X.Y.Z` от этого тега — для истории релиза. Её не мержить.
6. Проверить запуск workflow `Release` и ассеты релиза.

## Keep this file current

При изменении команд сборки/тестов или появлении линтера — обновляйте разделы «Команды» и
«Архитектура» в этом же коммите.
