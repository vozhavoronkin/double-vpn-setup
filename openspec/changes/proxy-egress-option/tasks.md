# Tasks

## 1. Ядро: модель настроек и детект

- [x] 1.1 Добавить `ProxyEgressSettings` (enabled, excludedNetworks) в профиль (`ProfileStore`) и модель состояния `ProxiesState` (сериализация в/из `/etc/amnezia/chain/proxies.json`, 0600, маркер `managed-by: amnezia-chain`); unit-тесты кодирования/декодирования, отсутствие файла = выключено
- [x] 1.2 Расширить `EnvironmentDetection`: список Docker-сетей (имя, подсеть, bridge), публичный IP сервера-выхода, идентификация сети AmneziaVPN по контейнеру; unit-тесты на разбор вывода `docker network ls/inspect`

## 2. Правила сервера-входа

- [x] 2.1 Реализовать `ProxyEgressRules.renderEntryScript`: цепочки `VPNCHAIN_HOST_OUT` (mangle OUTPUT) и `VPNCHAIN_DOCKER_OUT` (mangle PREROUTING) с `--ctdir REPLY`, исключениями lo/IP выхода/приватных сетей и маркировкой `0x51` по bridge включённых сетей; отдельный скрипт `/usr/local/bin/vpn-chain-proxy-rules.sh` + юнит `vpn-chain-proxy.service` (design D1–D2)
- [x] 2.2 Реализовать рендер IPv6-kill-switch (DROP исходящего с хоста и мостов включённых сетей, кроме lo/link-local) со снятием при выключении (design D6)
- [x] 2.3 Unit-тесты рендера: включён/выключен режим, `--ctdir REPLY` в обеих цепочках, исключения SSH/lo/LAN/IP выхода/сети AmneziaVPN/CLIENT_PORT, каждая включённая и исключённая сеть, идемпотентность (`-C || -I`), отключение удаляет ровно свои цепочки

## 3. Правила сервера-выхода

- [x] 3.1 Реализовать `ProxyEgressRules.renderExitScript`: `ip route replace <subnet> dev awg-relay` + MASQUERADE для каждой включённой подсети, чтение предыдущего списка из `proxies.json` и снятие устаревших маршрутов/NAT, запись состояния (design D3–D4)
- [x] 3.2 Unit-тесты: добавление/снятие подсетей при смене списка, идемпотентность повторного применения, полный отказ — правила отсутствуют

## 4. Применение и откат

- [x] 4.1 Шаги `ProvisioningEngine`: `proxy-exit` (С2) → `proxy-entry` (С1), при ошибке на входе — откат к выключенному состоянию на обоих серверах (design D5); unit-тесты порядка и отката
- [x] 4.2 Команда выключения режима: снятие цепочек/маршрутов/NAT/IPv6-правил и удаление `proxies.json` на обоих серверах; контейнер AmneziaVPN и SSH не затрагиваются; unit-тесты рендера очистки
- [x] 4.3 Дополнить `UninstallPlan` снятием proxy-правил по маркеру; unit-тесты плана очистки

## 5. UI: раздел «Прокси»

- [x] 5.1 `ProxiesViewModel`: загрузка/обновление списка сетей, применение, проверка фактического IP (хост + `docker exec … curl` по контейнерам включённых сетей), хранение настроек в профиле
- [x] 5.2 `ProxiesView` + раздел в `AppSections.all` (`AppRootView`): переключатель, пояснение про весь исходящий трафик, список сетей (имя/подсеть/bridge, AmneziaVPN всегда исключена), кнопки «Обновить список сетей»/«Применить правила»/«Проверить выход», предупреждение об ответственности; компоненты DesignSystem, русский текст без плейсхолдеров
- [x] 5.3 Результаты «Проверить выход» по каждому источнику (хост/контейнеры) с вердиктом совпадения с IP выхода; вёрстка и accessibility по нормам `app-interface`

## 6. Диагностика

- [x] 6.1 Проверки `ChecksEngine`: `proxy-host-egress`, `proxy-docker-networks` (детект дрейфа bridge), `proxy-exit-nat`, `proxy-egress-ip` — активны только при включённом режиме; unit-тесты на парсеры вывода
- [x] 6.2 Записи в таблице симптомов «прокси не выходит через сервер-выход» и «после включения пропал доступ» с причинами и шагами; unit-тесты таблицы

## 7. Интеграция и документация

- [x] 7.1 Прогнать `swift test`, `xcrun swift-format lint --strict -r -p Sources Tests Package.swift`, `openspec validate proxy-egress-option --strict` — всё зелёное; после добавления файлов в `Sources/VPNChainSetup` — `xcodegen generate` и сборка `xcodebuild … build`
- [x] 7.2 Обновить README (раздел «Прокси»: назначение, ограничения, ответственность) и CHANGELOG (0.2.0)
- [ ] 7.3 Приёмка на реальной паре серверов по сценарию issue #8 (хостовый прокси, контейнерный 3x-ui, выключение, падение выхода, reboot + дрейф сети); результаты зафиксировать в PR

## Workflow follow-up

- Archive the change (`openspec archive proxy-egress-option`) в ветке PR до мержа в `main`.
- Релиз 0.2.0 тегом `v0.2.0` по процедуре из AGENTS.md (отдельный от фичи релизный PR).
