import Foundation

/// Docker-сеть сервера-входа, участвующая в режиме проксирования.
/// Все значения приходят из детекта окружения — имена и подсети не хардкодятся.
public struct ProxyNetwork: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let subnet: String
    /// Имя bridge-интерфейса на хосте (`br-…`/`docker0`).
    public let bridge: String

    public var id: String { name }

    public init(name: String, subnet: String, bridge: String) {
        self.name = name
        self.subnet = subnet
        self.bridge = bridge
    }
}

/// Настройка режима проксирования, хранящаяся в профиле приложения.
/// Выключен по умолчанию; исключённые сети пользователь отмечает вручную.
public struct ProxyEgressSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Имена Docker-сетей, которые пользователь исключил из режима.
    public var excludedNetworks: [String]

    public init(enabled: Bool = false, excludedNetworks: [String] = []) {
        self.enabled = enabled
        self.excludedNetworks = excludedNetworks
    }

    public func isExcluded(_ network: String) -> Bool {
        excludedNetworks.contains(network)
    }
}

/// Результат применения режима: какие сети реально участвуют в маркировке.
public struct ProxyEgressApplied: Sendable, Equatable {
    public let enabled: Bool
    public let networks: [ProxyNetwork]

    public init(enabled: Bool, networks: [ProxyNetwork]) {
        self.enabled = enabled
        self.networks = networks
    }
}

/// Применённое на серверах состояние режима — `/etc/amnezia/chain/proxies.json` (0600).
/// Отсутствие файла или чужой маркер означают «выключено» (совместимость с уже
/// установленными парами: поведение цепочки не меняется).
public struct ProxiesState: Codable, Equatable, Sendable {
    public static let path = "/etc/amnezia/chain/proxies.json"
    public static let marker = "amnezia-chain"

    public let managedBy: String
    public let enabled: Bool
    /// Публичный IP сервера-выхода — для проверок и диагностики.
    public let exitIP: String?
    public let networks: [ProxyNetwork]

    private enum CodingKeys: String, CodingKey {
        case managedBy = "managed-by"
        case enabled
        case exitIP
        case networks
    }

    public init(enabled: Bool, exitIP: String?, networks: [ProxyNetwork]) {
        self.managedBy = Self.marker
        self.enabled = enabled
        self.exitIP = exitIP
        self.networks = networks
    }

    /// Загруженное состояние или nil: файла нет, он повреждён или чужой.
    public static func decode(_ text: String) -> ProxiesState? {
        guard let data = text.data(using: .utf8),
            let state = try? JSONDecoder().decode(ProxiesState.self, from: data),
            state.managedBy == marker
        else {
            return nil
        }
        return state
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    /// Команда чтения состояния для диагностики (пустой вывод = выключено).
    public static var readCommand: String { "cat \(path) 2>/dev/null" }

    public static func state(enabled: Bool, exitIP: String?, networks: [ProxyNetwork])
        -> ProxiesState
    {
        ProxiesState(enabled: enabled, exitIP: exitIP, networks: networks)
    }
}

/// Рендер идемпотентных правил режима и команд его применения (design D1–D6).
///
/// Вход и выход — отдельные скрипты с маркером `# managed-by: amnezia-chain`:
/// выключенный режим не меняет содержимое скриптов основной цепочки, установленных
/// до появления опции.
public enum ProxyEgressRules {
    public static let entryScriptPath = "/usr/local/bin/vpn-chain-proxy-rules.sh"
    public static let entryUnitPath = "/etc/systemd/system/vpn-chain-proxy.service"
    public static let exitScriptPath = "/usr/local/bin/vpn-chain-proxy-exit-rules.sh"
    public static let exitUnitPath = "/etc/systemd/system/vpn-chain-proxy-exit.service"

    /// Цепочки маркировки/блокировки, которые снимаются при выключении.
    public static let hostChain = "VPNCHAIN_HOST_OUT"
    public static let dockerChain = "VPNCHAIN_DOCKER_OUT"
    public static let hostChain6 = "VPNCHAIN_PROXY6_HOST"
    public static let dockerChain6 = "VPNCHAIN_PROXY6_DOCKER"

    /// Приватные/link-local/multicast/broadcast назначения: в туннель не маркируются.
    public static let privateDestinations = [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "224.0.0.0/4",
        "255.255.255.255/32",
    ]

    // MARK: Отбор сетей

    /// Сети, которые попадут в режим: сеть AmneziaVPN и сети, исключённые
    /// пользователем, не маркируются никогда.
    public static func selectedNetworks(
        all: [ProxyNetwork],
        settings: ProxyEgressSettings,
        amneziaNetworks: Set<String>
    ) -> [ProxyNetwork] {
        all.filter { network in
            !amneziaNetworks.contains(network.name)
                && !settings.isExcluded(network.name)
                && !network.subnet.isEmpty
                && !network.bridge.isEmpty
        }
    }

    // MARK: Скрипт входа

    /// Скрипт правил сервера-входа: две цепочки маркировки поверх существующего
    /// `fwmark → таблица 51821` плюс IPv6-kill-switch. При `enabled == false`
    /// скрипт только снимает свои правила и пишет состояние «выключено».
    public static func renderEntryScript(
        enabled: Bool,
        networks: [ProxyNetwork],
        exitIP: String,
        clientPort: String?
    ) -> String {
        let networkLines: String
        if enabled {
            networkLines =
                networks
                .map {
                    "iptables -t mangle -A \(dockerChain) -i '\($0.bridge)' -j MARK --set-mark \"$MARK\""
                }
                .joined(separator: "\n")
        } else {
            networkLines = "# режим выключен: Docker-сети не маркируются"
        }
        let clientPortLines: String
        if let clientPort, !clientPort.isEmpty {
            clientPortLines = """
                CLIENT_PORT='\(clientPort)'
                iptables -t mangle -A \(dockerChain) -p udp --sport "$CLIENT_PORT" -j RETURN
                iptables -t mangle -A \(dockerChain) -p tcp --sport "$CLIENT_PORT" -j RETURN
                """
        } else {
            clientPortLines = "CLIENT_PORT=''"
        }
        let stateJSON = ProxiesState(
            enabled: enabled, exitIP: exitIP.isEmpty ? nil : exitIP,
            networks: enabled ? networks : []
        ).json()
        let markSection: String
        if enabled {
            markSection = """
                # Хостовые сервисы: ответы клиентам, локальный трафик, IP выхода и приватные
                # сети не маркируются — иначе ответы прокси уходили бы в туннель.
                iptables -t mangle -N \(hostChain) 2>/dev/null || true
                iptables -t mangle -F \(hostChain)
                iptables -t mangle -A \(hostChain) -m conntrack --ctdir REPLY -j RETURN
                iptables -t mangle -A \(hostChain) -o lo -j RETURN
                iptables -t mangle -A \(hostChain) -d "$EXIT_IP" -j RETURN
                for dest in \(privateDestinations.map { "'\($0)'" }.joined(separator: " ")); do
                  iptables -t mangle -A \(hostChain) -d "$dest" -j RETURN
                done
                iptables -t mangle -A \(hostChain) -j MARK --set-mark "$MARK"
                iptables -t mangle -C OUTPUT -j \(hostChain) 2>/dev/null || iptables -t mangle -I OUTPUT 1 -j \(hostChain)

                # Docker-контейнеры: маркируется только входящее с bridge включённых сетей.
                iptables -t mangle -N \(dockerChain) 2>/dev/null || true
                iptables -t mangle -F \(dockerChain)
                iptables -t mangle -A \(dockerChain) -m conntrack --ctdir REPLY -j RETURN
                iptables -t mangle -A \(dockerChain) -d "$EXIT_IP" -j RETURN
                for dest in \(privateDestinations.map { "'\($0)'" }.joined(separator: " ")); do
                  iptables -t mangle -A \(dockerChain) -d "$dest" -j RETURN
                done
                \(clientPortLines)
                \(networkLines)
                iptables -t mangle -C PREROUTING -j \(dockerChain) 2>/dev/null || iptables -t mangle -I PREROUTING 1 -j \(dockerChain)

                # IPv6: туннель IPv4-only. Блокируем исходящий с хоста и из контейнеров,
                # кроме loopback и link-local, чтобы трафик не утекал мимо туннеля.
                # Ответы на входящие IPv6-соединения (SSH, прокси) не блокируем — иначе
                # сервер станет недоступен по IPv6.
                ip6tables -N \(hostChain6) 2>/dev/null || true
                ip6tables -F \(hostChain6)
                ip6tables -A \(hostChain6) -m conntrack --ctdir REPLY -j RETURN
                ip6tables -A \(hostChain6) -o lo -j RETURN
                ip6tables -A \(hostChain6) -d fe80::/10 -j RETURN
                ip6tables -A \(hostChain6) -j DROP
                ip6tables -C OUTPUT -j \(hostChain6) 2>/dev/null || ip6tables -I OUTPUT 1 -j \(hostChain6)

                ip6tables -N \(dockerChain6) 2>/dev/null || true
                ip6tables -F \(dockerChain6)
                ip6tables -A \(dockerChain6) -m conntrack --ctdir REPLY -j RETURN
                ip6tables -A \(dockerChain6) -d fe80::/10 -j RETURN
                \(networks.map { "ip6tables -A \(dockerChain6) -i '\($0.bridge)' -j DROP" }.joined(separator: "\n"))
                ip6tables -C PREROUTING -j \(dockerChain6) 2>/dev/null || ip6tables -I PREROUTING 1 -j \(dockerChain6)
                """
        } else {
            markSection = """
                # Выключено: снимаем только свои цепочки, правила Amnezia не трогаем.
                ip6tables -D OUTPUT -j \(hostChain6) 2>/dev/null || true
                ip6tables -D PREROUTING -j \(dockerChain6) 2>/dev/null || true
                """
        }
        let cleanup = """
            MARK=0x51
            EXIT_IP='\(exitIP)'

            # Идемпотентность: повторное применение удаляет прежние вставки, не дублируя их.
            while iptables -t mangle -D OUTPUT -j \(hostChain) 2>/dev/null; do :; done
            while iptables -t mangle -D PREROUTING -j \(dockerChain) 2>/dev/null; do :; done
            iptables -t mangle -F \(hostChain) 2>/dev/null || true
            iptables -t mangle -X \(hostChain) 2>/dev/null || true
            iptables -t mangle -F \(dockerChain) 2>/dev/null || true
            iptables -t mangle -X \(dockerChain) 2>/dev/null || true
            while ip6tables -D OUTPUT -j \(hostChain6) 2>/dev/null; do :; done
            while ip6tables -D PREROUTING -j \(dockerChain6) 2>/dev/null; do :; done
            ip6tables -F \(hostChain6) 2>/dev/null || true
            ip6tables -X \(hostChain6) 2>/dev/null || true
            ip6tables -F \(dockerChain6) 2>/dev/null || true
            ip6tables -X \(dockerChain6) 2>/dev/null || true
            """
        return """
            #!/usr/bin/env bash
            set -Eeuo pipefail
            # managed-by: amnezia-chain

            \(cleanup)

            \(markSection)

            # Состояние режима: нужно для идемпотентности, диагностики дрейфа и удаления.
            mkdir -p /etc/amnezia/chain
            chmod 0700 /etc/amnezia/chain 2>/dev/null || true
            cat > '\(ProxiesState.path)' <<'VPNCHAIN_STATE'
            \(stateJSON)
            VPNCHAIN_STATE
            chmod 0600 '\(ProxiesState.path)'
            echo "vpn-chain: правила проксирования исходящего трафика применены (enabled=\(enabled ? "true" : "false"))"
            """
    }

    // MARK: Скрипт выхода

    /// Скрипт сервера-выхода: маршруты и MASQUERADE для подсетей включённых сетей.
    /// Прежний список читается из `proxies.json`, устаревшие маршруты/NAT снимаются.
    public static func renderExitScript(
        enabled: Bool,
        networks: [ProxyNetwork],
        wanInterface: String,
        exitIP: String
    ) -> String {
        let subnets = enabled ? networks.map(\.subnet) : []
        let stateJSON = ProxiesState(
            enabled: enabled, exitIP: exitIP.isEmpty ? nil : exitIP,
            networks: enabled ? networks : []
        ).json()
        return """
            #!/usr/bin/env bash
            set -Eeuo pipefail
            # managed-by: amnezia-chain

            WAN='\(wanInterface)'
            SUBNETS='\(subnets.joined(separator: " "))'
            STATE='\(ProxiesState.path)'

            # Прежний список подсетей: без него после исключения сети остались бы
            # висячие маршрут и MASQUERADE на сервере-выходе.
            OLD_SUBNETS=''
            if [ -f "$STATE" ]; then
              OLD_SUBNETS=$(sed -n 's/.*"subnet"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$STATE" | tr '\\n' ' ')
            fi

            for s in $OLD_SUBNETS; do
              case " $SUBNETS " in
                *" $s "*) continue ;;
              esac
              ip route del "$s" dev awg-relay 2>/dev/null || true
              while iptables -t nat -D POSTROUTING -s "$s" -o "$WAN" -j MASQUERADE 2>/dev/null; do :; done
            done

            for s in $SUBNETS; do
              ip route replace "$s" dev awg-relay
              iptables -t nat -C POSTROUTING -s "$s" -o "$WAN" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$s" -o "$WAN" -j MASQUERADE
            done

            mkdir -p /etc/amnezia/chain
            chmod 0700 /etc/amnezia/chain 2>/dev/null || true
            cat > "$STATE" <<'VPNCHAIN_STATE'
            \(stateJSON)
            VPNCHAIN_STATE
            chmod 0600 "$STATE"
            echo "vpn-chain: маршруты и NAT проксирования применены (enabled=\(enabled ? "true" : "false"), подсети: ${SUBNETS:-нет})"
            """
    }

    // MARK: Юниты и команды применения

    public static let entryUnitTemplate: String = """
        [Unit]
        Description=Amnezia chain: proxy egress via exit server
        After=docker.service awg-quick@awg-relay.service vpn-chain.service network-online.target
        Wants=network-online.target

        [Service]
        Type=oneshot
        ExecStart=\(entryScriptPath)
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
        """

    public static let exitUnitTemplate: String = """
        [Unit]
        Description=Amnezia chain exit: routes/NAT for proxy egress
        After=network-online.target awg-quick@awg-relay.service vpn-chain-exit.service
        Wants=network-online.target

        [Service]
        Type=oneshot
        ExecStart=\(exitScriptPath)
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
        """

    public static func installEntryCommand(
        enabled: Bool,
        networks: [ProxyNetwork],
        exitIP: String,
        clientPort: String?
    ) -> String {
        let script = FileDelivery.command(
            path: entryScriptPath,
            content: renderEntryScript(
                enabled: enabled, networks: networks, exitIP: exitIP, clientPort: clientPort),
            mode: "0755"
        )
        let unit = FileDelivery.command(
            path: entryUnitPath, content: entryUnitTemplate, mode: "0644")
        return """
            \(script)
            \(unit)
            systemctl daemon-reload
            systemctl enable vpn-chain-proxy.service
            systemctl restart vpn-chain-proxy.service
            """
    }

    public static func installExitCommand(
        enabled: Bool,
        networks: [ProxyNetwork],
        wanInterface: String,
        exitIP: String
    ) -> String {
        let script = FileDelivery.command(
            path: exitScriptPath,
            content: renderExitScript(
                enabled: enabled, networks: networks, wanInterface: wanInterface, exitIP: exitIP),
            mode: "0755"
        )
        let unit = FileDelivery.command(
            path: exitUnitPath, content: exitUnitTemplate, mode: "0644")
        return """
            \(script)
            \(unit)
            systemctl daemon-reload
            systemctl enable vpn-chain-proxy-exit.service
            systemctl restart vpn-chain-proxy-exit.service
            """
    }

    // MARK: Действия для движка

    public static func entryActions(
        enabled: Bool,
        networks: [ProxyNetwork],
        exitIP: String,
        clientPort: String?
    ) -> [ShellAction] {
        [
            ShellAction(
                id: "proxy-entry",
                title: enabled
                    ? "Маркировка хостового и контейнерного трафика + IPv6-kill-switch"
                    : "Снятие правил режима проксирования на сервере-входе",
                check: nil,
                apply: installEntryCommand(
                    enabled: enabled, networks: networks, exitIP: exitIP,
                    clientPort: clientPort),
                timeout: 120
            )
        ]
    }

    public static func exitActions(
        enabled: Bool,
        networks: [ProxyNetwork],
        wanInterface: String,
        exitIP: String
    ) -> [ShellAction] {
        [
            ShellAction(
                id: "proxy-exit",
                title: enabled
                    ? "Маршруты и MASQUERADE для Docker-сетей сервера-входа"
                    : "Снятие маршрутов и NAT режима проксирования на сервере-выходе",
                check: nil,
                apply: installExitCommand(
                    enabled: enabled, networks: networks, wanInterface: wanInterface,
                    exitIP: exitIP),
                timeout: 120
            )
        ]
    }
}
