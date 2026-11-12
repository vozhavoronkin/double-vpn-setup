# Design

## Context

Маршрутизация relay-туннеля на сервере-входе уже построена на `fwmark 0x51 → таблица 51821 → default dev awg-relay + blackhole` (.ConfigureC1.swift, `renderRulesScript`). Сегодня маркируется только клиентский трафик из моста контейнера AmneziaVPN (`VPNCHAIN_MARK` в mangle PREROUTING). Опция из issue #8 добавляет источники маркировки для остального исходящего трафика входа: хостовых сервисов (mangle OUTPUT) и Docker-контейнеров (mangle PREROUTING по bridge сетей). Правила применяются идемпотентными bash-скриптами с маркером `# managed-by: amnezia-chain`, персистентность — systemd-юнитами `vpn-chain.service` / `vpn-chain-exit.service`. Детект окружения (`EnvironmentDetection`) уже умеет разбирать `docker network inspect`.

## Goals / Non-Goals

**Goals:**
- Переиспользовать существующую маркировку/таблицу 51821 — только новые источники MARK.
- Идемпотентность, детект без хардкода, полный откат по маркеру, kill-switch blackhole.
- UI-раздел «Прокси» и диагностика в существующих паттернах (DesignSystem, ChecksEngine).

**Non-Goals:**
- Установка/настройка самих прокси-сервисов (Xray и т.п.).
- Индивидуальные правила на процесс/прокси — только глобальный режим + исключения сетей.
- IPv6 в relay-туннеле, TPROXY.

## Decisions

### D1. Отдельный модуль `ProxyEgress` вместо расширения ConfigureC1/C2
Рендер правил режима — новый файл `Sources/VPNChainCore/Provisioning/ProxyEgress.swift` (`ProxyEgressRules`): вход (`renderEntryScript`) и выход (`renderExitScript`). Оба скрипта режима — отдельные файлы с собственными юнитами: `/usr/local/bin/vpn-chain-proxy-rules.sh` + `vpn-chain-proxy.service` (С1) и `/usr/local/bin/vpn-chain-proxy-exit-rules.sh` + `vpn-chain-proxy-exit.service` (С2). Альтернатива — вплести правила в существующие скрипты`/юниты — отвергнута: выключенный режим не должен менять содержимое уже установленных скриптов (совместимость с парами, установленными до опции), а снятие режима не требует восстанавливать прежний текст `vpn-chain-exit-rules.sh`.

### D2. Правила входа — две цепочки поверх fwmark
`VPNCHAIN_HOST_OUT` (mangle OUTPUT): RETURN для `--ctdir REPLY`, `-o lo`, `-d <IP выхода>`, приватных/link-local/multicast/broadcast; затем `MARK 0x51`. `VPNCHAIN_DOCKER_OUT` (mangle PREROUTING): RETURN для `--ctdir REPLY`, приватных сетей и IP выхода; затем по `-i <bridge>` каждой включённой сети `MARK 0x51`. Вставка jump'ов идемпотентна (`-C || -I`). Пакеты самому хосту (SSH) не затрагиваются: PREROUTING фильтрует только по `-i` мостов, OUTPUT — только исходящие. Значения (bridge, IP выхода, метка, таблица) — из детекта и констант `ConfigureC1`.

### D3. Выход — маршруты + MASQUERADE по списку подсетей
`ip route replace <subnet> dev awg-relay` + `MASQUERADE -s <subnet> -o $WAN` для каждой включённой подсети. Список применённых подсетей читается из `/etc/amnezia/chain/proxies.json` перед применением: подсети, которых больше нет, — `ip route del` и `-D MASQUERADE`. Хостовый источник `10.99.0.1` уже покрыт существующим MASQUERADE relay-подсети.

### D4. Состояние — `/etc/amnezia/chain/proxies.json`
JSON: `{ "managed-by": "amnezia-chain", "enabled": bool, "exitIP": "...", "networks": [{"name","subnet","bridge"}] }`, права 0600. Пишется на обоих серверах. Отсутствие файла = выключено (совместимость). Настройка в приложении — `ProxyEgressSettings` (enabled, excludedNetworks) в профиле (`ProfileStore`); UI-состояние не источник истины для серверов.

### D5. Порядок применения и откат — шаги ProvisioningEngine
Новые шаги: `proxy-exit` (С2: маршруты/NAT/файл состояния) → `proxy-entry` (С1: цепочки/файл состояния/IPv6). При ошибке на `proxy-entry` выполняется `proxy-disable` (снятие на обоих по `proxies.json`), режим остаётся выключенным, ошибка показывается. Выключение = применение «пустого» списка с enabled=false. Хук в установку основной цепочки не добавляется: режим применяется отдельно из раздела «Прокси».

### D6. IPv6-kill-switch
При включённом режиме в цепочке `VPNCHAIN6` (уже существует в ip6tables) добавляются правила DROP исходящего с хоста (`-o <WAN>` в OUTPUT, кроме loopback/link-local) и с мостов включённых сетей — вместо этого отдельные managed-правила в `ip6tables OUTPUT`/существующей цепочке; снимаются при выключении. Решение зафиксировано в issue («по умолчанию — блокировка»).

### D7. Детект
`EnvironmentDetection` расширяется: список всех Docker-сетей с subnet/bridge (`docker network ls` + `docker network inspect`), публичный IP выхода (`curl -4s https://api.ipify.org` или аналогичный из существующих проверок), идентификация сети AmneziaVPN — по контейнеру из существующего детекта. Проверка фактического IP: `curl -4s` с хоста входа и `docker exec <container> curl -4s` для контейнеров включённых сетей.

### D8. Диагностика
4 новые проверки в `ChecksEngine` (`proxy-host-egress`, `proxy-docker-networks`, `proxy-exit-nat`, `proxy-egress-ip`), активные только при включённом режиме (иначе skipped). Две записи в `Troubleshooting`. `UninstallPlan` дополняется снятием proxy-правил по `proxies.json` перед общей очисткой.

## Risks / Trade-offs

- [Глобальный режим заворачивает и обновления пакетов/DNS/Docker Pull входа] → заявлено в UI-пояснении; blackhole при падении выхода роняет исходящий трафик хоста (SSH-входящие живут) → kill-switch осознанно выбран в issue.
- [Пересоздание Docker-сети меняет bridge → правила молча не работают] → проверка `proxy-docker-networks` ловит дрейф; повторное применение пересчитывает bridge.
- [Цепочки OUTPUT могут маркировать трафик самого relay-туннеля] → исключение `-d <IP выхода>`; unit-тесты на рендер покрывают.
- [Масштабирование списка сетей при частом apply] → подсети берутся из `proxies.json`, отработанные удаляются `del`, идемпотентность покрыта тестами.
- [IPv6-блокировка может сломать хостовые сервисы с IPv6-only upstream] → компромисс зафиксирован в issue; предупреждение в UI.

## Migration Plan

Изменение чисто аддитивное: без включения режима серверы не меняются. Откат — выключить режим в UI (полное снятие правил) или удалить ветку. Релиз 0.2.0, опция выключена по умолчанию.

## Open Questions

- Каким сервисом проверять внешний IP (`api.ipify.org` vs другие) — выбрать при реализации по доступности; на контракт не влияет.
- Нужна ли кнопка «выборочно применить только сетям без хоста» — нет, вне scope (глобальный режим).
