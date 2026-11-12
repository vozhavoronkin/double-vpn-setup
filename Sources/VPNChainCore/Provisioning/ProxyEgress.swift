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

    /// Цепочки режима: docker — маркировка/блокировка контейнеров, host — цепочки
    /// прежних версий (больше не создаются, но снимаются для миграции и удаления).
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

    /// Скрипт правил сервера-входа: область режима — только Docker-контейнеры
    /// (маркировка `VPNCHAIN_DOCKER_OUT` поверх существующего `fwmark → таблица 51821`,
    /// IPv6-блокировка контейнеров, SNAT подсетей в туннель). Хостовой трафик сервера
    /// не затрагивается. При `enabled == false` скрипт снимает свои правила (включая
    /// хостовые цепочки прежних версий) и пишет состояние «выключено».
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
                # Область режима — только Docker-контейнеры: маркируется входящий
                # с bridge включённых сетей. Ответы клиентам прокси (ctdir REPLY),
                # IP сервера-выхода (иначе петля WireGuard) и приватные сети
                # не маркируются.
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

                # IPv6: туннель IPv4-only, блокируем исходящий из включённых контейнеров,
                # чтобы трафик не утекал мимо туннеля. Цепочка — в таблице mangle:
                # PREROUTING существует только там (в filter-таблице её нет, и вставка
                # падает с «No chain/target/match by that name»).
                ip6tables -t mangle -N \(dockerChain6) 2>/dev/null || true
                ip6tables -t mangle -F \(dockerChain6)
                ip6tables -t mangle -A \(dockerChain6) -m conntrack --ctdir REPLY -j RETURN
                ip6tables -t mangle -A \(dockerChain6) -d fe80::/10 -j RETURN
                \(networks.map { "ip6tables -t mangle -A \(dockerChain6) -i '\($0.bridge)' -j DROP" }.joined(separator: "\n"))
                ip6tables -t mangle -C PREROUTING -j \(dockerChain6) 2>/dev/null || ip6tables -t mangle -I PREROUTING 1 -j \(dockerChain6)

                # SNAT в туннель: cryptokey routing (AllowedIPs) пропускает только
                # адреса туннеля, поэтому контейнерный трафик входит в awg-relay уже
                # с адресом туннеля. Маршруты и NAT на сервере-выходе не нужны — это
                # заодно исключает конфликт одинаковых Docker-подсетей на входе и выходе.
                for s in \(networks.map { "'\($0.subnet)'" }.joined(separator: " ")); do
                  iptables -t nat -C POSTROUTING -s "$s" -o awg-relay -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$s" -o awg-relay -j MASQUERADE
                done
                """
        } else {
            markSection = """
                # Выключено: снимаем только свои цепочки, правила Amnezia не трогаем.
                ip6tables -t mangle -D PREROUTING -j \(dockerChain6) 2>/dev/null || true
                """
        }
        let cleanup = """
            MARK=0x51
            EXIT_IP='\(exitIP)'

            # SNAT-очистка: прежние подсети читаем из состояния, чтобы после исключения
            # сети из режима не остались висячие MASQUERADE-правила.
            OLD_SUBNETS=''
            if [ -f '\(ProxiesState.path)' ]; then
              OLD_SUBNETS=$(sed -n 's/.*"subnet"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' '\(ProxiesState.path)' | tr '\\n' ' ')
            fi
            for s in $OLD_SUBNETS; do
              while iptables -t nat -D POSTROUTING -s "$s" -o awg-relay -j MASQUERADE 2>/dev/null; do :; done
            done

            # Идемпотентность: повторное применение удаляет прежние вставки, не дублируя их.
            while iptables -t mangle -D OUTPUT -j \(hostChain) 2>/dev/null; do :; done
            while iptables -t mangle -D PREROUTING -j \(dockerChain) 2>/dev/null; do :; done
            iptables -t mangle -F \(hostChain) 2>/dev/null || true
            iptables -t mangle -X \(hostChain) 2>/dev/null || true
            iptables -t mangle -F \(dockerChain) 2>/dev/null || true
            iptables -t mangle -X \(dockerChain) 2>/dev/null || true
            while ip6tables -D OUTPUT -j \(hostChain6) 2>/dev/null; do :; done
            while ip6tables -t mangle -D PREROUTING -j \(dockerChain6) 2>/dev/null; do :; done
            ip6tables -F \(hostChain6) 2>/dev/null || true
            ip6tables -X \(hostChain6) 2>/dev/null || true
            ip6tables -t mangle -F \(dockerChain6) 2>/dev/null || true
            ip6tables -t mangle -X \(dockerChain6) 2>/dev/null || true
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

    /// Скрипт сервера-выхода: SNAT выполняется на сервере-входе (см. `renderEntryScript`),
    /// поэтому здесь только очистка следов прежней схемы (маршруты и MASQUERADE
    /// добавлялись до перехода на SNAT) и запись состояния.
    public static func renderExitScript(
        enabled: Bool,
        networks: [ProxyNetwork],
        wanInterface: String,
        exitIP: String
    ) -> String {
        let stateJSON = ProxiesState(
            enabled: enabled, exitIP: exitIP.isEmpty ? nil : exitIP,
            networks: enabled ? networks : []
        ).json()
        return """
            #!/usr/bin/env bash
            set -Eeuo pipefail
            # managed-by: amnezia-chain

            WAN='\(wanInterface)'
            STATE='\(ProxiesState.path)'

            # Прежний список подсетей: если на сервере остались маршрут/MASQUERADE от
            # старой схемы — снимаем. Новых правил на сервере-выходе не появляется.
            OLD_SUBNETS=''
            if [ -f "$STATE" ]; then
              OLD_SUBNETS=$(sed -n 's/.*"subnet"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$STATE" | tr '\\n' ' ')
            fi
            for s in $OLD_SUBNETS; do
              ip route del "$s" dev awg-relay 2>/dev/null || true
              while iptables -t nat -D POSTROUTING -s "$s" -o "$WAN" -j MASQUERADE 2>/dev/null; do :; done
            done

            mkdir -p /etc/amnezia/chain
            chmod 0700 /etc/amnezia/chain 2>/dev/null || true
            cat > "$STATE" <<'VPNCHAIN_STATE'
            \(stateJSON)
            VPNCHAIN_STATE
            chmod 0600 "$STATE"
            echo "vpn-chain: сервер-выход чист (маршруты и NAT режима не требуются, enabled=\(enabled ? "true" : "false"))"
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
