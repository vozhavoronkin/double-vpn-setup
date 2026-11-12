# Tasks

## 1. Ядро: модель настроек и детект

- [x] 1.1 Добавить `ProxyEgressSettings` (enabled, excludedNetworks) в профиль (`ProfileStore`) и модель состояния `ProxiesState` (сериализация в/из `/etc/amnezia/chain/proxies.json`, 0600, маркер `managed-by: amnezia-chain`); unit-тесты кодирования/декодирования, отсутствие файла = выключено
- [x] 1.2 Расширить детект: список Docker-сетей (имя, подсеть, bridge), публичный IP сервера-выхода, идентификация сети AmneziaVPN; unit-тесты на разбор вывода `docker network ls/inspect`
- [x] 1.3 Определение сети AmneziaVPN объединением сигналов (сети контейнера ∪ сеть с `BRIDGE` из env, минус дефолтная `bridge`); регрессионные тесты на реальные кейсы: `BRIDGE=amn0`, контейнер AmneziaVPN в двух сетях, прокси в `bridge`

## 2. Правила сервера-входа

- [x] 2.1 Реализовать `ProxyEgressRules.renderEntryScript`: цепочка `VPNCHAIN_DOCKER_OUT` (mangle PREROUTING) с `--ctdir REPLY`, исключениями IP выхода/приватных сетей/`CLIENT_PORT` и маркировкой `0x51` по bridge включённых сетей; отдельный скрипт `/usr/local/bin/vpn-chain-proxy-rules.sh` + юнит `vpn-chain-proxy.service` (design D1–D2)
- [x] 2.2 SNAT контейнерных подсетей в туннель: `MASQUERADE -s <subnet> -o awg-relay` в начале `nat POSTROUTING`; снятие правил выбывших подсетей по `proxies.json` (design D3)
- [x] 2.3 IPv6-kill-switch контейнеров: цепочка `VPNCHAIN_PROXY6_DOCKER` в таблице `mangle` (RETURN для REPLY и link-local, DROP по bridge включённых сетей); хостовой IPv6 не блокируется (design D6)
- [x] 2.4 Unit-тесты рендера: включён/выключен режим, `--ctdir REPLY`, исключения IP выхода/LAN/`CLIENT_PORT`, каждая включённая и исключённая сеть, SNAT и его очистка, идемпотентность (`-C || -I`), отсутствие хостовых цепочек, IPv6-цепочка в `mangle`

## 3. Сервер-выход

- [x] 3.1 `renderExitScript`: правила не добавляются; снимаются следы прежней схемы (маршруты и MASQUERADE по списку из `proxies.json`), пишется состояние (design D3, D4)
- [x] 3.2 Unit-тесты: в enabled-скрипте нет `ip route replace`/добавления MASQUERADE, очистка выполняется, состояние пишется

## 4. Применение и откат

- [x] 4.1 Шаги `ProvisioningEngine`: `proxy-exit` (С2) → `proxy-entry` (С1), при ошибке на входе — откат к выключенному состоянию на обоих серверах (design D5); unit-тесты порядка и отката
- [x] 4.2 Команда выключения режима: снятие цепочек/SNAT/IPv6-правил и обновление `proxies.json`; контейнер AmneziaVPN и SSH не затрагиваются
- [x] 4.3 Дополнить `UninstallPlan` снятием proxy-правил (цепочки, IPv6, SNAT подсетей) по маркеру; unit-тесты плана очистки
- [x] 4.4 Показ реальной причины ошибки: `ProvisioningError.commandFailed` → шаг, код выхода и хвост stderr/журнала в UI (`UserMessages`)

## 5. UI: раздел «Прокси»

- [x] 5.1 `ProxiesViewModel`: загрузка/обновление списка сетей, применение, проверка фактического IP контейнеров (`docker exec … curl`/`wget`), хранение настроек в профиле
- [x] 5.2 `ProxiesView` + раздел в `AppSections.all`: переключатель, пояснение (только контейнеры отмеченных сетей), список сетей (AmneziaVPN всегда исключена, `bridge` доступна), кнопки «Обновить список сетей»/«Применить правила»/«Проверить выход», предупреждение об ответственности; русский текст без плейсхолдеров
- [x] 5.3 Результаты «Проверить выход» по каждому контейнеру; для контейнеров без curl/wget — «нет ответа» с пояснением, что проверять нужно вручную через прокси

## 6. Диагностика

- [x] 6.1 Проверки `ChecksEngine`: `proxy-docker-networks` (дрейф bridge), `proxy-nat-tunnel` (SNAT на входе), `proxy-egress-ip` (фактический IP из контейнеров) — активны только при включённом режиме; unit-тесты
- [x] 6.2 Записи в таблице симптомов «прокси не выходит через сервер-выход» и «после включения пропал доступ»; unit-тесты таблицы

## 7. Интеграция и документация

- [x] 7.1 Прогнать `swift test`, `xcrun swift-format lint --strict -r -p Sources Tests Package.swift`, `openspec validate proxy-egress-option --strict`; `xcodegen generate` и `xcodebuild … build`
- [x] 7.2 Обновить README (раздел «Прокси») и CHANGELOG (Unreleased → релиз)
- [x] 7.3 Приёмка на реальной паре: контейнерный прокси (socks5) — `curl --socks5-hostname … http://api.ipify.org` вернул IP сервера-выхода; google/TLS/данные проходят; SSH и клиентская цепочка Amnezia живы; откат при ошибке работает; сервер-выход очищен от следов прежней схемы. Ограничение окружения: провайдер выхода фильтрует 443 к Telegram-диапазонам — обходится FakeTLS на прокси.
- [ ] 7.4 Дополнительные сценарии приёмки: падение сервера-выхода (kill-switch для контейнеров), reboot входа и пересоздание Docker-сети (детект дрейфа)

## Workflow follow-up

- Archive the change (`openspec archive proxy-egress-option`) в ветке PR до мержа в `main`.
- Релиз — отдельным релизным PR по процедуре из AGENTS.md (версия и CHANGELOG не смешиваются с фичей).
