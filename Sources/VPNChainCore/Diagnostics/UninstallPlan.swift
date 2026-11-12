import Foundation

/// Команда uninstall для конкретного артефакта (задача 6.4).
public struct UninstallCommand: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let command: String

    public init(id: String, title: String, command: String) {
        self.id = id
        self.title = title
        self.command = command
    }
}

/// План uninstall: удаляются ТОЛЬКО артефакты с маркером `managed-by: amnezia-chain`
/// и из перечня установки. Контейнер AmneziaVPN, SSH и собранное ПО не затрагиваются
/// (ПО — только по явному подтверждению, отдельным списком).
public enum UninstallPlan {
    /// Инвентарь установленных артефактов — источник истины для тестов и UI.
    public static let inventory: [String] = [
        "awg-quick@awg-relay",
        "vpn-chain.service",
        "vpn-chain-exit.service",
        "vpn-chain-rules.sh",
        "vpn-chain-exit-rules.sh",
        "vpn-chain-proxy.service",
        "vpn-chain-proxy-rules.sh",
        "vpn-chain-proxy-exit.service",
        "vpn-chain-proxy-exit-rules.sh",
        "/etc/amnezia/amneziawg/awg-relay.conf",
        "/etc/sysctl.d/99-vpn-chain.conf",
        "/etc/amnezia/chain",
        "proxies.json",
        "VPNCHAIN",
        "VPNCHAIN_HOST_OUT",
        "VPNCHAIN_DOCKER_OUT",
        "table 51821",
        "--dport 51828",
    ]

    // MARK: Сервер-вход

    public static func entryCommands() -> [UninstallCommand] {
        [
            UninstallCommand(
                id: "entry-stop",
                title: "Остановка relay и юнитов",
                command: """
                    awg-quick down awg-relay 2>/dev/null || true
                    systemctl disable --now awg-quick@awg-relay 2>/dev/null || true
                    systemctl disable --now vpn-chain.service 2>/dev/null || true
                    """
            ),
            UninstallCommand(
                id: "entry-proxy",
                title: "Снятие режима проксирования (цепочки и IPv6-блокировка)",
                command: """
                    systemctl disable --now vpn-chain-proxy.service 2>/dev/null || true
                    while iptables -t mangle -D OUTPUT -j VPNCHAIN_HOST_OUT 2>/dev/null; do :; done
                    while iptables -t mangle -D PREROUTING -j VPNCHAIN_DOCKER_OUT 2>/dev/null; do :; done
                    iptables -t mangle -F VPNCHAIN_HOST_OUT 2>/dev/null || true
                    iptables -t mangle -X VPNCHAIN_HOST_OUT 2>/dev/null || true
                    iptables -t mangle -F VPNCHAIN_DOCKER_OUT 2>/dev/null || true
                    iptables -t mangle -X VPNCHAIN_DOCKER_OUT 2>/dev/null || true
                    while ip6tables -D OUTPUT -j VPNCHAIN_PROXY6_HOST 2>/dev/null; do :; done
                    while ip6tables -D PREROUTING -j VPNCHAIN_PROXY6_DOCKER 2>/dev/null; do :; done
                    ip6tables -F VPNCHAIN_PROXY6_HOST 2>/dev/null || true
                    ip6tables -X VPNCHAIN_PROXY6_HOST 2>/dev/null || true
                    ip6tables -F VPNCHAIN_PROXY6_DOCKER 2>/dev/null || true
                    ip6tables -X VPNCHAIN_PROXY6_DOCKER 2>/dev/null || true
                    """
            ),
            UninstallCommand(
                id: "entry-routing",
                title: "Удаление policy routing и kill-switch",
                command: """
                    while ip rule del table 51821 2>/dev/null; do :; done
                    ip route flush table 51821 2>/dev/null || true
                    iptables -t nat -D POSTROUTING -o awg-relay -j RETURN 2>/dev/null || true
                    iptables -t mangle -C PREROUTING -j VPNCHAIN_MARK 2>/dev/null && iptables -t mangle -D PREROUTING -j VPNCHAIN_MARK 2>/dev/null || true
                    iptables -t mangle -F VPNCHAIN_MARK 2>/dev/null || true
                    iptables -t mangle -X VPNCHAIN_MARK 2>/dev/null || true
                    """
            ),
            UninstallCommand(
                id: "entry-firewall",
                title: "Удаление цепочек VPNCHAIN/VPNCHAIN6",
                command: """
                    iptables -C DOCKER-USER -j VPNCHAIN 2>/dev/null && iptables -D DOCKER-USER -j VPNCHAIN 2>/dev/null || true
                    iptables -F VPNCHAIN 2>/dev/null || true
                    iptables -X VPNCHAIN 2>/dev/null || true
                    ip6tables -C DOCKER-USER -j VPNCHAIN6 2>/dev/null && ip6tables -D DOCKER-USER -j VPNCHAIN6 2>/dev/null || true
                    ip6tables -F VPNCHAIN6 2>/dev/null || true
                    ip6tables -X VPNCHAIN6 2>/dev/null || true
                    """
            ),
            UninstallCommand(
                id: "entry-files",
                title: "Удаление конфигов, скриптов, юнитов и persist-файла",
                command: """
                    rm -f '/etc/amnezia/amneziawg/awg-relay.conf' '/etc/amnezia/amneziawg/awg-relay.conf.bak.'*
                    rm -f '/usr/local/bin/vpn-chain-rules.sh' '/etc/systemd/system/vpn-chain.service'
                    rm -f '/usr/local/bin/vpn-chain-proxy-rules.sh' '/etc/systemd/system/vpn-chain-proxy.service'
                    rm -f '/etc/sysctl.d/99-vpn-chain.conf' '/etc/sysctl.d/99-vpn-chain.conf.bak.'*
                    systemctl daemon-reload 2>/dev/null || true
                    """
            ),
            UninstallCommand(
                id: "entry-state",
                title: "Удаление состояния (/etc/amnezia/chain)",
                command: "rm -rf '/etc/amnezia/chain'"
            ),
        ]
    }

    // MARK: Сервер-выход

    public static func exitCommands(dockerSubnet: String, clientSubnet: String?)
        -> [UninstallCommand]
    {
        var subnets = ["'\(dockerSubnet)'"]
        if let clientSubnet, !clientSubnet.isEmpty {
            subnets.append("'\(clientSubnet)'")
        }
        subnets.append("'10.99.0.0/24'")
        // Удаление по номеру правила: MASQUERADE создаётся с `-o <WAN>`, и точное
        // совпадение спецификации при удалении без знания WAN невозможно.
        let natRemoval = """
            for s in \(subnets.joined(separator: " ")); do
              while n=$(iptables -t nat -L POSTROUTING --line-numbers -n | awk -v s="$s" '/MASQUERADE/ && index($0, s) {print $1; exit}'); [ -n "$n" ]; do
                iptables -t nat -D POSTROUTING "$n" 2>/dev/null || break
              done
            done
            """
        return [
            UninstallCommand(
                id: "exit-stop",
                title: "Остановка relay и юнитов",
                command: """
                    awg-quick down awg-relay 2>/dev/null || true
                    systemctl disable --now awg-quick@awg-relay 2>/dev/null || true
                    systemctl disable --now vpn-chain-exit.service 2>/dev/null || true
                    """
            ),
            UninstallCommand(
                id: "exit-nat",
                title: "Удаление MASQUERADE",
                command: natRemoval
            ),
            UninstallCommand(
                id: "exit-proxy",
                title: "Снятие маршрутов/NAT режима проксирования",
                command: """
                    systemctl disable --now vpn-chain-proxy-exit.service 2>/dev/null || true
                    if [ -f '/etc/amnezia/chain/proxies.json' ]; then
                      for s in $(sed -n 's/.*"subnet"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' '/etc/amnezia/chain/proxies.json'); do
                        ip route del "$s" dev awg-relay 2>/dev/null || true
                        while n=$(iptables -t nat -L POSTROUTING --line-numbers -n | awk -v s="$s" '/MASQUERADE/ && index($0, s) {print $1; exit}'); [ -n "$n" ]; do
                          iptables -t nat -D POSTROUTING "$n" 2>/dev/null || break
                        done
                      done
                    fi
                    """
            ),
            UninstallCommand(
                id: "exit-forward",
                title: "Удаление FORWARD/INPUT/MSS-правил",
                command: """
                    while iptables -D FORWARD -i awg-relay -j ACCEPT 2>/dev/null; do :; done
                    while iptables -D FORWARD -o awg-relay -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
                    while iptables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
                    while iptables -D INPUT -p udp --dport 51828 -j ACCEPT 2>/dev/null; do :; done
                    """
            ),
            UninstallCommand(
                id: "exit-files",
                title: "Удаление конфигов, скриптов, юнитов и persist-файла",
                command: """
                    rm -f '/etc/amnezia/amneziawg/awg-relay.conf' '/etc/amnezia/amneziawg/awg-relay.conf.bak.'*
                    rm -f '/usr/local/bin/vpn-chain-exit-rules.sh' '/etc/systemd/system/vpn-chain-exit.service'
                    rm -f '/usr/local/bin/vpn-chain-proxy-exit-rules.sh' '/etc/systemd/system/vpn-chain-proxy-exit.service'
                    rm -f '/etc/sysctl.d/99-vpn-chain.conf' '/etc/sysctl.d/99-vpn-chain.conf.bak.'*
                    systemctl daemon-reload 2>/dev/null || true
                    """
            ),
        ]
    }

    /// НЕ выполняется автоматически: удаление собранного ПО — только по явному
    /// подтверждению пользователя (спека chain-diagnostics).
    public static let optionalSoftwareRemoval: [UninstallCommand] = [
        UninstallCommand(
            id: "software-binaries",
            title: "Удалить собранные бинарники (awg, awg-quick, amneziawg-go)",
            command: "rm -f /usr/bin/awg /usr/bin/awg-quick /usr/bin/amneziawg-go"
        ),
        UninstallCommand(
            id: "software-sources",
            title: "Удалить исходники из /tmp",
            command: "rm -rf /tmp/amneziawg-tools /tmp/amneziawg-go"
        ),
    ]
}
