# Proposal

## Why

Помимо AmneziaVPN на сервере-входе часто поднимают дополнительные прокси в Docker (Xray/3x-ui, Shadowsocks, SOCKS5, MTProto). Сейчас в туннель к серверу-выходу уходит только трафик клиентов AmneziaWG (отбор по `fwmark`), поэтому клиенты дополнительных прокси видят IP входа, а не выхода. Нужна выключенная по умолчанию опция, направляющая трафик Docker-контейнеров сервера-входа через сервер-выход (issue #8).

## What Changes

- Новый режим «Прокси» (по умолчанию выключен): трафик контейнеров отмеченных Docker-сетей, кроме сети AmneziaVPN, маркируется и уходит через relay-туннель. Хостовой трафик сервера-входа не затрагивается.
- На сервере-входе: цепочка маркировки `VPNCHAIN_DOCKER_OUT` (mangle PREROUTING) поверх существующей маршрутизации `fwmark → таблица 51821`; SNAT подсетей в туннель (`MASQUERADE -o awg-relay`) — туннель использует cryptokey routing; IPv6-блокировка контейнеров в таблице `mangle`. Существующие правила Amnezia не меняются.
- На сервере-выходе: правила не добавляются. Удаляются только следы прежней схемы (маршруты и MASQUERADE по списку из состояния), чтобы не конфликтовать с Docker-подсетями выхода.
- Порядок применения «выход → вход» с откатом при ошибке на входе.
- Применённое состояние — `/etc/amnezia/chain/proxies.json` (0600, маркер `managed-by: amnezia-chain`) на обоих серверах; настройка (вкл/выкл, исключённые сети) — в профиле приложения.
- Новый раздел «Прокси» в UI: переключатель, список Docker-сетей с чекбоксами, применение, проверка фактического IP из контейнеров.
- Новые диагностические проверки (`proxy-docker-networks`, `proxy-nat-tunnel`, `proxy-egress-ip`) и записи в таблицу симптомов.
- Ошибки применения показываются с шагом, кодом выхода и хвостом журнала сервера.
- Полное снятие правил при выключении/удалении только по маркеру; контейнер AmneziaVPN и SSH не затрагиваются.
- Приложение НЕ устанавливает и не настраивает сами прокси-сервисы — только обеспечивает маршрут.

## Capabilities

### New Capabilities
- `proxy-egress`: опциональный режим направления трафика Docker-контейнеров сервера-входа через сервер-выход: маркировка по bridge, SNAT в туннель, идемпотентное применение/откат/удаление по маркеру, хранение состояния, IPv6-kill-switch контейнеров.

### Modified Capabilities
- `app-interface`: новый раздел «Прокси» в sidebar (`AppSections.all`): переключатель, список Docker-сетей, применение, проверка фактического выхода, предупреждение об ответственности пользователя.
- `chain-diagnostics`: новые проверки proxy-* и записи в таблицу симптомов; диагностика дрейфа Docker-сетей.

## Impact

- `Sources/VPNChainCore/Provisioning/ProxyEgress.swift` — рендер правил режима, скрипты и юниты.
- `Sources/VPNChainCore/Provisioning/ProxyEgressDetection.swift` — детект Docker-сетей, сети AmneziaVPN и IP выхода.
- `Sources/VPNChainCore/Provisioning/ProvisioningEngine.swift` — шаги применения в порядке «выход → вход», откат.
- `Sources/VPNChainCore/Storage/ProfileStore.swift` — настройка режима.
- `Sources/VPNChainCore/Diagnostics/ChecksEngine.swift`, `Troubleshooting.swift`, `UninstallPlan.swift` — проверки, симптомы, очистка.
- `Sources/VPNChainSetup/Views/ProxiesView.swift`, `ViewModels/ProxiesViewModel.swift`, `AppRootView.swift` — раздел «Прокси».
- Unit-тесты рендера правил; приёмка на реальной паре; README/CHANGELOG; релиз 0.3.0.
