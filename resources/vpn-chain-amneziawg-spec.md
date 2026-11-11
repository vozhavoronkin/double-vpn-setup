# ТЗ: VPN-цепочка «весь трафик через AmneziaWG»

**Топология:** Клиент → Сервер 1 (вход, AmneziaVPN) → Сервер 2 (выход) → Интернет
**Версия документа:** 1.0 (2026-11) · **Исполнитель:** агент (opencode) · **Язык реализации:** Bash
**Документ самодостаточен:** все команды, шаблоны конфигов и критерии приёмки — внутри. Внешние ссылки в разделе 13 — только справочные.

---

## 1. Что нужно получить (постановка)

Полностью весь трафик клиентского устройства (TCP, UDP, ICMP, DNS) должен проходить цепочку из двух серверов, причём **оба участка цепочки — клиент→Сервер 1 и Сервер 1→Сервер 2 — работают по протоколу AmneziaWG** (обфусцированный WireGuard), а не по «голому» WireGuard.

Ответ на вопрос «можно ли весь трафик через amneziaWG» — **да**, и это достигается двумя вещами:

1. **Клиентский участок** уже AmneziaWG: приложение AmneziaVPN устанавливает на Сервер 1 контейнер `amnezia-awg` и само выдаёт клиенту конфиг с full tunnel (`AllowedIPs = 0.0.0.0/0`). Ничего менять не нужно, контейнер приложения не трогаем.
2. **Межсерверный участок** переводится с обычного WireGuard на AmneziaWG: на хостах Сервера 1 и Сервера 2 поднимается отдельный туннель `awg-relay` на связке `amneziawg-go` (userspace) + `awg`/`awg-quick` (tools). Свои параметры обфускации `Jc/Jmin/Jmax/S1/S2/H1–H4`, свои ключи, свой порт.

Что **не** входит в задачу (и не должно быть сломано):

- Трафик самих серверов (SSH, обновления пакетов) идёт напрямую, минуя цепочку. Управляющий доступ должен сохраниться при любом состоянии туннеля.
- Контейнер `amnezia-awg` и его конфиг `/opt/amnezia/awg/wg0.conf` не модифицируются: приложение перезаписывает их при добавлении пользователей, любые ручные правки будут потеряны.
- Клиентские конфиги, сгенерированные приложением, не редактируются на сервере.

## 2. Целевая архитектура

```
[Устройство клиента]
   │  AmneziaVPN-приложение: AmneziaWG, full tunnel 0.0.0.0/0,
   │  DNS через туннель, KillSwitch включён
   ▼ ① AmneziaWG (обфускация из конфига приложения)
[Сервер 1 — вход, Docker]
   ├─ контейнер amnezia-awg (установлен приложением, НЕ трогаем):
   │    расшифровывает ①, NAT-ит клиентов в IP контейнера (172.X.0.2)
   ├─ хост: br-XXXX (сеть Docker, напр. 172.26.0.0/16)
   ├─ хост: awg-relay = amneziawg-go + awg-quick, Table = off
   ├─ policy routing: ip rule iif br-XXXX → table 51821 → default dev awg-relay
   │    (+ blackhole default как kill-switch, если туннель упал)
   └─ MSS clamp, ip6tables DROP для br-XXXX (анти-утечка IPv6)
   ▼ ② AmneziaWG (свои параметры обфускации, порт UDP 51828)
[Сервер 2 — выход, чистый Debian/Ubuntu]
   ├─ awg-relay: та же связка amneziawg-go + awg-quick
   ├─ расшифровка ②, AllowedIPs пира = внутренние подсети
   └─ NAT: MASQUERADE → eth0, MSS clamp, ip_forward
   ▼
[Интернет]
```

### 2.1. План адресации

| Элемент | Значение | Комментарий |
|---|---|---|
| Подсеть relay-туннеля | `10.99.0.0/24` | С1 = `10.99.0.1`, С2 = `10.99.0.2` |
| Порт relay-туннеля | `51828/UDP` | Только С2 слушает; С1 инициирует (Endpoint у С1) |
| MTU интерфейса `awg-relay` | `1420` | `Jmax=80` << 1420 — мусорные пакеты не фрагментируются |
| Docker-сеть приложения на С1 | авто-детект (напр. `172.26.0.0/16`) | бридж `br-XXXX` + IP контейнера |
| Подсеть клиентов AWG на С1 | авто-детект (обычно `10.8.1.0/24`) | нужна только если NAT внутри контейнера отключён |
| Keepalive | `PersistentKeepalive = 25` | на стороне С1 |

### 2.2. Путь пакета (номера соответствуют схеме)

1. Клиентский пакет (src `10.8.1.5`) зашифровывается AmneziaWG и уходит на С1. Контейнер расшифровывает, внутри контейнера NAT-ит: src становится `172.26.0.2` (IP контейнера), пакет выходит на хост через `br-XXXX`.
2. Хост С1: `ip rule iif br-XXXX` → таблица 51821 → `default dev awg-relay`. Пакет попадает в userspace-демон `amneziawg-go`, шифруется второй раз (участок ②) и уходит с eth0 на `С2:51828/UDP`. Наружу идёт только UDP-трафик между двумя известными IP.
3. С2: демонтация ②, src остаётся `172.26.0.2` → MASQUERADE в eth0 → интернет.
4. Ответ: С2 де-NAT-ит (dst `172.26.0.2`) → cryptokey routing пира отправляет в туннель → С1 расшифровывает ② → dst `172.26.0.2` попадает в main-таблицу (маршрут Docker-сети уже есть) → в контейнер → внутренний conntrack контейнера возвращает src `10.8.1.5` → клиенту.

Ключевое следствие: **Сервер 2 не делает NAT по клиентской подсети, а по Docker-подсети Сервера 1** — скрипт С1 обязан обнаружить её и вшить в payload для С2 (`AllowedIPs` пира и `MASQUERADE`).

## 3. Программные компоненты и установка

На **обоих** серверах (хост, не в контейнере) ставятся две вещи. Ядро не трогаем, модуль ядра не нужен — `awg-quick` при отсутствии модуля сам запускает userspace-демон `amneziawg-go` (проверено по исходникам `src/wg-quick/linux.bash`: ветка fallback вызывает `amneziawg-go "$INTERFACE"`). Предупреждение `[!] Missing kernel module. Falling back to slow userspace implementation` в логе — **норма**, не ошибка.

### 3.1. amneziawg-tools (`awg`, `awg-quick`)

```bash
apt-get update && apt-get install -y git make gcc
git clone https://github.com/amnezia-vpn/amneziawg-tools /tmp/amneziawg-tools
make -C /tmp/amneziawg-tools/src -j"$(nproc)"
make -C /tmp/amneziawg-tools/src install        # поставит awg, awg-quick, man, юниты
awg --version && command -v awg-quick
```

По умолчанию (WITH_SYSTEMDUNITS) ставится юнит `awg-quick@.service`. Проверить: `systemctl cat awg-quick@.service`. Если юнит не установился — создать вручную по шаблону из раздела 9.4.

### 3.2. amneziawg-go (userspace-демон)

```bash
apt-get install -y golang-go build-essential
git clone https://github.com/amnezia-vpn/amneziawg-go /tmp/amneziawg-go
make -C /tmp/amneziawg-go -j"$(nproc)"
make -C /tmp/amneziawg-go install
amneziawg-go --version && command -v amneziawg-go
```

**Критично:** у свежего `amneziawg-go` требования к версии Go выше, чем в дистрибутивных пакетах (Debian 12 ставит Go 1.19 — этого мало). Алгоритм в скрипте:

1. Распарсить директиву `go 1.XX` из `go.mod` склонированного репозитория.
2. Если системный `go version` < требуемой — скачать актуальный tarball с `https://go.dev/dl/` (архитектурозависимо: `linux-amd64` / `linux-arm64`), распаковать в `/usr/local/go`, использовать `/usr/local/go/bin/go`. Системный Go не удалять.
3. Сборку повторить с этим Go.

Оба сервера должны собираться из **одного и того же состояния репозитория** (клонировать в один день; допустимо зафиксировать один commit hash в переменных скрипта) — это гарантирует совместимость версий протокола на концах.

### 3.3. Опционально (не в основном объёме)

Ubuntu/Debian-пакет из PPA `ppa:amnezia/ppa` (`apt install amneziawg`, ядерный модуль, нужен `linux-headers-$(uname -r)`, `modinfo amneziawg` для проверки) — путь ускорения для нагруженных серверов. См. раздел 12.1. Базовая поставка — userspace.

## 4. Параметры обфускации (AmneziaWG 1.0-style)

Для relay-участка используем классический набор параметров — он совместим с любой сборкой `amneziawg-go`. Генерируются один раз скриптом С1, записываются **идентично** в конфиги обоих серверов.

| Параметр | Диапазон | Правило | Генерация |
|---|---|---|---|
| `Jc` | 1–128, рекоменд. 4–12 | может отличаться на концах | случайное 3–12 |
| `Jmin` | рекоменд. 8, < `Jmax` | может отличаться | 8 |
| `Jmax` | ≤ 1280, рекоменд. 80, **< MTU** | может отличаться | 80 |
| `S1` | ≤ 1132, рекоменд. 15–150 | **должен совпадать** | случайное 50–120 |
| `S2` | ≤ 1188, рекоменд. 15–150 | **должен совпадать** | случайное 50–120, повтор генерации пока `S2 == S1 + 56` |
| `H1`–`H4` | 5–2147483647 | **должны совпадать**, четыре значения попарно различны | 4 случайных числа, проверка уникальности |

Правила сверки (источник — README ядерного модуля AmneziaWG): совпадать обязаны `S1`, `S2` и `H1`–`H4`; `Jc/Jmin/Jmax` могут различаться (в конфигах для простоты пишем одинаковые). Значения `H1=1, H2=2, H3=3, H4=4` и нули означают «обфускация выключена» — такие значения запрещены. Параметры 1.5/2.0/3.x (`I1`–`I5`, диапазоны `H1-H4` вида `a-b`, `S3/S4`, `HeaderProtectionKey`, `RandomTrailers`) **не использовать** — см. раздел 12.2, если понадобится усиление.

Проверка совпадения на работающей паре: `awg showconf awg-relay` на обоих серверах должен показать одинаковые `S1, S2, H1–H4`.

## 5. Общие требования к скриптам

Файлы: `amnezia-chain-server1.sh` (С1) и генерируемый им payload для С2. Требования к обоим:

- `#!/usr/bin/env bash`, `set -Eeuo pipefail`, `trap 'echo "[ОШИБКА] строка $LINENO" >&2' ERR`.
- Только root (`[[ $EUID -eq 0 ]]`), проверка ОС (Debian 11/12/13, Ubuntu 20.04/22.04/24.04), архитектуры (`x86_64`/`aarch64`).
- **Идемпотентность**: повторный запуск ничего не ломает. Ключи и параметры в `/etc/amnezia/chain/` (права `0700` на каталог, `0600` на файлы); если существуют — переиспользуются, а не перегенерируются.
- Все изменяемые артефакты снабжать маркерами `# managed-by: amnezia-chain` и при повторном запуске обновлять только их; чужие файлы не трогать; перед перезаписью — `.bak.<timestamp>`.
- Без интерактивных вопросов; параметры через флаги (см. 6.1).
- Приватные ключи не печатать в stdout/логи. Исключение — payload для С2 (в нём ключи обязаны быть), с явным предупреждением пользователю.
- Никаких `curl ... | bash`: всё скачивается в файл и исполняется из файла.
- Если активен ufw/firewalld — не отключать его, а добавлять разрешающие правила (порт 51828/UDP на С2, SSH не трогать). Про панель/sg провайдера — напоминание пользователю в конце вывода.

## 6. Скрипт Сервера 1 — `amnezia-chain-server1.sh`

### 6.1. Интерфейс

```text
amnezia-chain-server1.sh                # установка/обновление (идемпотентно)
amnezia-chain-server1.sh --print-payload  # заново напечатать one-liner для С2
amnezia-chain-server1.sh --status       # состояние туннелей и правил
amnezia-chain-server1.sh --uninstall    # снять всё, что ставил (контейнер приложения не трогать)
```

### 6.2. Шаги (по порядку)

1. **Детект окружения приложения.** Найти контейнер: `docker ps --format '{{.Names}}' | grep -i awg` (ожидаeтся `amnezia-awg`). Если Docker/контейнер не найден — выйти с ошибкой «сначала установите AmneziaWG из приложения AmneziaVPN».
2. **Детект Docker-сети и IP контейнера**: `docker inspect <контейнер>` → имя сети → `docker network inspect <сеть>` → `Name` бриджа (`br-XXXX`), `Subnet` (напр. `172.26.0.0/16`) → IP контейнера в этой сети. Все три значения сохранить в переменные и в файл состояния `/etc/amnezia/chain/env`.
3. **Детект клиентской подсети** (мягкий, необязательный): `docker exec <контейнер> sh -c 'cat /opt/amnezia/awg/wg0.conf 2>/dev/null'` → из строк `Address` взять подсеть (обычно `10.8.1.0/24`). Не получилось — просто не включать её в payload (см. 7.2).
4. **Установка ПО** по разделу 3 (проверять `command -v awg awg-quick amneziawg-go`, ставить только недостающее; версии собирать из одного commit — хэш хранить в `/etc/amnezia/chain/env`).
5. **Генерация секретов** (если нет): `awg genkey`/`awg pubkey` для `s1-relay` и `s2-relay` в `/etc/amnezia/chain/`, плюс файл `obf.conf` с `S1, S2, H1–H4` по правилам раздела 4.
6. **Конфиг relay С1** — `/etc/amnezia/amneziawg/awg-relay.conf` (шаблон 9.1). `Table = off` обязателен.
7. **Systemd**: включить `awg-quick@awg-relay`; создать `vpn-chain.service` (шаблон 9.4) — пересоздание правил после перезагрузки, `After=docker.service awg-quick@awg-relay.service network-online.target`.
8. **Сетевые правила С1** (функция `apply_rules`, вызывается и из юнита, и из скрипта; перед применением — очистка только собственных объектов по маркерам):
   ```bash
   sysctl -w net.ipv4.ip_forward=1   # + запись в /etc/sysctl.d/99-vpn-chain.conf
   # политическая маршрутизация (только трафик ИЗ бриджа приложения!)
   ip rule del iif "$BRIDGE" table 51821 2>/dev/null || true
   ip rule add iif "$BRIDGE" table 51821 priority 100
   ip route replace default dev awg-relay table 51821
   ip route replace blackhole default table 51821 metric 42760   # kill-switch: если relay упал — трафик клиентов блокируется, а не уходит напрямую
   # firewall: только через DOCKER-USER (санкционированное docker место), своей цепочкой
   iptables -N VPNCHAIN 2>/dev/null || true
   iptables -C DOCKER-USER -j VPNCHAIN 2>/dev/null || iptables -I DOCKER-USER 1 -j VPNCHAIN
   iptables -F VPNCHAIN
   iptables -A VPNCHAIN -i "$BRIDGE" -o awg-relay -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
   iptables -A VPNCHAIN -i "$BRIDGE" -o awg-relay -j ACCEPT
   iptables -A VPNCHAIN -i awg-relay -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
   ip6tables -N VPNCHAIN6 2>/dev/null || true
   ip6tables -C DOCKER-USER -j VPNCHAIN6 2>/dev/null || ip6tables -I DOCKER-USER 1 -j VPNCHAIN6
   ip6tables -F VPNCHAIN6
   ip6tables -A VPNCHAIN6 -i "$BRIDGE" -j DROP    # анти-утечка IPv6 клиентов
   # rp_filter, чтобы ответы из туннеля не резались
   sysctl -w net.ipv4.conf.all.rp_filter=2
   ```
   Проверить фактическое имя цепочки DOCKER-USER через `iptables -S DOCKER-USER`; если Docker перезапускался и пересоздал правила — повторный запуск скрипта/юнита восстанавливает.
9. **Подстановка в payload С2**: IP/порт С2, ключи `s1-relay.pub`/`s2-relay.priv`, `obf.conf`, Docker-подсеть С1 (+ клиентская подсеть, если найдена). Сформировать `amnezia-chain-server2-payload.sh` по разделу 7, сжать: `gzip | base64 -w0`.
10. **Вывод пользователю**: сводка (бридж, подсети, порт), команда проверки, и однострочная команда для С2 вида:
    ```bash
    echo 'H4sIA...' | base64 -d | gunzip | bash
    ```
    с предупреждением: команда содержит приватные ключи, вводить только в root-шелле С2, не публиковать.

## 7. Payload для Сервера 2 (генерируется скриптом С1)

Самодостаточный скрипт (install + configure), все секреты и адреса уже вшиты. Шаги:

1. Установка ПО (раздел 3), включая fallback на официальный tarball Go при старой версии. Повторный запуск пропускает установку.
2. Конфиг `/etc/amnezia/amneziawg/awg-relay.conf` (шаблон 9.2). **Без `Table = off`** — `awg-quick` сам добавит маршруты обратно в туннель из `AllowedIPs` пира.
3. Включить `awg-quick@awg-relay`.
4. Правила выхода:
   ```bash
   sysctl -w net.ipv4.ip_forward=1           # + persist в /etc/sysctl.d/99-vpn-chain.conf
   # SSH не блокировать: только добавляем разрешения
   iptables -C INPUT -p udp --dport 51828 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 51828 -j ACCEPT
   iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
   iptables -C FORWARD -i awg-relay -o "$WAN" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg-relay -o "$WAN" -j ACCEPT
   iptables -C FORWARD -i "$WAN" -o awg-relay -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WAN" -o awg-relay -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
   iptables -t nat -C POSTROUTING -s "$DOCKER_SUBNET" -o "$WAN" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$DOCKER_SUBNET" -o "$WAN" -j MASQUERADE
   ```
   `$WAN` — интерфейс с default-маршрутом (`ip route show default`), `$DOCKER_SUBNET` — подсеть Docker С1, вшитая при генерации (+ клиентская подсеть, если была обнаружена).
5. Персистентность правил: юнит `vpn-chain-exit.service` (oneshot, идентичный по смыслу блок правил) или `netfilter-persistent` — на выбор исполнителя, но правила обязаны восстановиться после `reboot`.
6. В конце: печать `awg show awg-relay`, подсказка про панель провайдера («откройте UDP 51828 в firewall/cloud-группе С2»).

## 8. Клиентская сторона (инструкция пользователю, не скрипт)

1. Приложение AmneziaVPN → подключение к С1 по AmneziaWG (уже установлено). Обновить приложение до последней версии (поддержка актуальных поколений протокола).
2. Убедиться, что режим «раздельного туннелирования» (split tunneling) **выключен** — по умолчанию весь трафик идёт в туннель.
3. Включить KillSwitch в настройках приложения; DNS — из конфига (AmneziaDNS/1.1.1.1), резолвится через туннель.
4. Опционально при проблемах с UDP/QUIC-приложениями: в настройках соединения в приложении снизить MTU до `1380` (двойная инкапсуляция; TCP подстраивается сам через MSS clamp, а вот крупным UDP-пакетам помогает только меньший MTU клиента).
5. Доступ к локальной сети устройства определяется настройками приложения и вне рамок этой схемы.

## 9. Шаблоны конфигов (источник истины для генерации)

`{{...}}` — плейсхолдеры, заполняются скриптом на этапе выполнения (это не пропуски в документе).

### 9.1. С1: `/etc/amnezia/amneziawg/awg-relay.conf`

```ini
[Interface]
Address = 10.99.0.1/24
Table = off
MTU = 1420
Jc = {{JC}}
Jmin = {{JMIN}}
Jmax = {{JMAX}}
S1 = {{S1}}
S2 = {{S2}}
H1 = {{H1}}
H2 = {{H2}}
H3 = {{H3}}
H4 = {{H4}}
# ListenPort не задаём: С1 инициирует соединение сам

[Peer]
# Сервер 2 (выход)
PublicKey = {{S2_RELAY_PUB}}
Endpoint = {{S2_IP}}:51828
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### 9.2. С2: `/etc/amnezia/amneziawg/awg-relay.conf`

```ini
[Interface]
Address = 10.99.0.2/24
ListenPort = 51828
MTU = 1420
Jc = {{JC}}
Jmin = {{JMIN}}
Jmax = {{JMAX}}
S1 = {{S1}}
S2 = {{S2}}
H1 = {{H1}}
H2 = {{H2}}
H3 = {{H3}}
H4 = {{H4}}

[Peer]
# Сервер 1 (вход): принимает расшифрованный клиентский трафик
# src = Docker-подсеть С1 (+ клиентская подсеть AWG, если обнаружена)
PublicKey = {{S1_RELAY_PUB}}
AllowedIPs = 10.99.0.0/24, {{DOCKER_SUBNET_C1}}{{CLIENT_SUBNET_C1}}
```

Внимание к асимметрии: у С1 `AllowedIPs = 0.0.0.0/0` при `Table = off` (маршрутизация только политикой, default-маршрут хоста не трогается); у С2 — только внутренние подсети, **никогда** `0.0.0.0/0`, иначе С2 завернёт собственный SSH-трафик в туннель.

### 9.3. С1: `/etc/systemd/system/vpn-chain.service`

```ini
[Unit]
Description=Amnezia chain: policy routing for AWG relay
After=docker.service awg-quick@awg-relay.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-chain-rules.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

`vpn-chain-rules.sh` — тот же блок правил из 6.2 (шаг 8), оформленный функцией с идемпотентностью (повторный вызов безопасен). Скрипт С1 кладёт его в `/usr/local/bin/` с правами 0755. Аналогичный `vpn-chain-exit.service` — на С2 (блок из 7.4).

### 9.4. Ручной юнит `awg-quick@.service` (если `make install` его не поставил)

```ini
[Unit]
Description=AmneziaWG via awg-quick for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
ExecStart=/usr/bin/awg-quick up %i
ExecStop=/usr/bin/awg-quick down %i

[Install]
WantedBy=multi-user.target
```

Переменная `WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go` гарантирует userspace-fallback даже если бинарь лежит вне стандартного PATH (`make install` обычно кладёт в `/usr/bin`, но проверить `command -v amneziawg-go`).

## 10. Проверка (Definition of Done)

Порядок: С2 → С1 → клиент. Агент обязан прогнать все команды и приложить вывод.

| # | Где | Команда | Ожидаемо |
|---|---|---|---|
| 1 | С2 | `awg show awg-relay` | интерфейс поднят, `listening on 51828` |
| 2 | С1 | `awg show awg-relay` | `latest handshake` с С2 не старше 2–3 минут, transfer rx/tx растёт |
| 3 | С1 | `ip rule show` | `100: iif "br-XXXX" lookup 51821` |
| 4 | С1 | `ip route show table 51821` | `default dev awg-relay` + `blackhole default metric 42760` |
| 5 | С1 | `iptables -S DOCKER-USER` | `-j VPNCHAIN` и правила из 6.2 (шаг 8) |
| 6 | С1 | `docker exec amnezia-awg awg show` | рукопожатия клиентов приложения (проверка, что контейнер не задет) |
| 7 | Клиент | подключиться в приложении → `2ip.ru` / `ifconfig.me` | **IP Сервера 2** |
| 8 | Клиент | `browserleaks.com/dns` или `dnsleaktest.com` | резолвер один, из туннеля, без утечек |
| 9 | Клиент | `test-ipv6.com` | IPv6 отсутствует/не течёт (правило VPNCHAIN6) |
| 10 | С2 | `tcpdump -ni $(WAN) 'udp port 51828'` | только UDP от С1; весь остальной трафик — уже де-обфусцированный исходящий |
| 11 | Оба | `reboot`, затем пункты 1–7 | всё восстановилось само (юниты `awg-quick@awg-relay`, `vpn-chain.service`) |
| 12 | С1 | `systemctl stop awg-quick@awg-relay` → клиент проверяет `2ip.ru` | страница не открывается (blackhole), **IP клиента не светится**; `start` — снова работает |

Пункт 12 — серверный kill-switch: при падении туннеля трафик клиентов блокируется, а не уходит напрямую мимо цепочки.

## 11. Troubleshooting

| Симптом | Причина | Диагностика / лечение |
|---|---|---|
| Нет handshake между С1 и С2 | UDP 51828 закрыт (панель провайдера, ufw) | `nc -uvz S2_IP 51828`; открыть порт у провайдера: `ufw allow 51828/udp` |
| Нет handshake, порт открыт | Несовпадают `S1/S2/H1–H4` на концах | `awg showconf awg-relay` на обоих — сравнить; перезапустить оба |
| Нет handshake, параметры совпадают | Разные сборки amneziawg-go (несовместимые поколения протокола) | Собрать оба из одного commit (раздел 3.2) |
| Handshake есть, интернета нет | На С2 не включён `ip_forward` / нет MASQUERADE / в `AllowedIPs` пира нет Docker-подсети С1 | `iptables -t nat -S POSTROUTING`, `sysctl net.ipv4.ip_forward`, `awg showconf awg-relay` на С2 |
| Handshake есть, интернета нет | На С1 потерялись `ip rule`/маршрут 51821 (после ребута Docker пересоздал цепочки) | `systemctl status vpn-chain`, перезапустить юнит; проверить `iptables -S DOCKER-USER` |
| Всё работало, сломалось после добавления пользователя в приложении | Норма: приложение переписало конфиг контейнера | Ничего не делать — host-level relay не зависит от этого; если не работает — см. строку ниже |
| Приложение переустановлено, Docker-сеть пересоздана (новая подсеть) | У С2 устарели `AllowedIPs`/MASQUERADE | Перезапустить `amnezia-chain-server1.sh` (сгенерирует новый payload), повторить one-liner на С2 |
| Работает, но медленно | Userspace-реализация / MTU | Раздел 12.1 (ядро) или MTU 1380 у клиента (раздел 8.4); проверить `awg show awg-relay` — нет ли постоянных новых handshake |
| Клиент: HTTPS открывается, часть UDP-приложений нет | Крупные UDP-пакеты не проходят двойную инкапсуляцию | MTU 1380 в приложении (раздел 8.4) |
| Пропал SSH на С1 | Ошибка в policy routing (правило затронуло host-трафик) | Правило обязано быть строго `iif br-XXXX`; через консоль провайдера: `ip rule del iif br-XXXX table 51821` |
| В логе С1 `[!] Missing kernel module... Falling back to slow userspace` | Это не ошибка | Норма для userspace-режима |
| IPv6-утечка у клиента | Правило VPNCHAIN6 не применилось / Docker пересоздал DOCKER-USER | `ip6tables -S DOCKER-USER`; перезапустить `vpn-chain.service` |

Отладка userspace-демона: на обоих концах `awg-quick down awg-relay && LOG_LEVEL=verbose amneziawg-go -f awg-relay` и смотреть строки `Received message with unknown type` (несовпадение обфускации) в момент попытки handshake с другого конца.

## 12. Опциональные улучшения (вне основного объёма)

### 12.1. Ядерный модуль вместо userspace (производительность)

Ubuntu: `add-apt-repository ppa:amnezia/ppa && apt install amneziawg` (+ `linux-headers-$(uname -r)`, при обновлении ядра — перезагрузка). Debian: репозиторий `https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main` + ключ `57290828`. Проверка: `modinfo amneziawg`. После установки модуля `awg-quick up awg-relay` начнёт использовать ядро автоматически (fallback-ветка в `awg-quick` не сработает). Конфиги менять не нужно.

### 12.2. Усиление relay-участка до AmneziaWG 2.0/3.1

Классические параметры (раздел 4) маскируют WireGuard от пассивного DPI. Поколения 2.0–3.1 добавляют защиту от статистического анализа (диапазоны заголовков `H1-H4 = a-b`, `S3/S4`, `HeaderProtectionKey`, `RandomTrailers`, `DisableCookies`) — актуально, если участок С1→С2 пересекает юрисдикцию с агрессивной фильтрацией. Требования: свежая сборка `amneziawg-go` на обоих концах, строгая идентичность `S1–S4`/`H1–H4`/`HeaderProtectionKey`, при `HeaderProtectionKey` — `S1, S2 >= 12`. Внедрять отдельной итерацией после стабильной работы базовой схемы.

## 13. Источники (проверены 2026-11)

- Установка amneziawg-go (официальная инструкция): `https://docs.amnezia.org/documentation/instructions/install-amneziawg-go`
- Ядерный модуль (PPA): `https://docs.amnezia.org/documentation/instructions/install-amneziawg-kernel-module-linux`
- amneziawg-tools (сборка, структура): `https://github.com/amnezia-vpn/amneziawg-tools`
- amneziawg-go: `https://github.com/amnezia-vpn/amneziawg-go`
- Fallback `awg-quick` на userspace, `Table = off`, путь конфигов `/etc/amnezia/amneziawg/`: исходник `src/wg-quick/linux.bash` в репозитории amneziawg-tools
- Разбор параметров обфускации и правил совпадения: `https://tunnelhq.com/blog/amneziawg-parameters-explained`

## 14. Чек-лист агента (сводно)

- [ ] Скрипт С1: детект контейнера/бриджа/подсетей, идемпотентные ключи и обфускация, ПО (3.1–3.2), конфиг 9.1, DOCKER-USER-правила, policy routing + blackhole, юниты, payload, one-liner
- [ ] Payload С2: самостоятельная установка ПО с fallback Go, конфиг 9.2, NAT/FORWARD/clamp, персистентность, подсказка про порт провайдера
- [ ] Флаги С1: `--print-payload`, `--status`, `--uninstall`
- [ ] Секреты: права 0600, без печати приватных ключей, предупреждение про payload
- [ ] Контейнер `amnezia-awg` не модифицирован (проверка: `docker exec amnezia-awg awg show` работает, конфиг контейнера нетронут)
- [ ] Прогнана вся таблица проверки (раздел 10), включая reboot и серверный kill-switch (п. 12)
- [ ] Миграция со старой схемы (если она была развёрнута): `systemctl disable --now vpn-chain.service awg-quick@wg0 2>/dev/null`; `ip link del wg0 2>/dev/null`; удалить старые ключи/юниты, затем накатить новую схему. Старый plain-WireGuard relay не должен остаться ни в одном автозапуске.
