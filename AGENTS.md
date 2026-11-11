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
openspec validate macos-vpn-chain-setup-app --strict
```

- `VPNChainSetup.xcodeproj` генерируется и **не** хранится в git — после добавления/удаления
  файлов в `Sources/VPNChainSetup` запускайте `xcodegen generate`.
- Линтера в проекте нет; стиль — по окружающему коду (4 пробела, `public` в core, русские
  doc-комментарии к нетривиальным местам).

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
  статуса, диагностики, клиента), `Services/AppServices.swift` — сборка зависимостей.

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

## Keep this file current

При изменении команд сборки/тестов или появлении линтера — обновляйте разделы «Команды» и
«Архитектура» в этом же коммите.
