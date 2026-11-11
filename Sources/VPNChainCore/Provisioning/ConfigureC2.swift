import Foundation

/// Шаги конфигурации Сервера 2 — выход (задача 5.1, ТЗ раздел 7).
public enum ConfigureC2 {
    public static let rulesScriptPath = "/usr/local/bin/vpn-chain-exit-rules.sh"
    public static let unitPath = "/etc/systemd/system/vpn-chain-exit.service"

    /// Определение WAN-интерфейса: `ip route show default` → «default via … dev eth0 …».
    public static let wanDetectCommand = "ip route show default"

    public static func parseDefaultInterface(_ output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("default ") else { continue }
            let tokens = trimmed.split(separator: " ").map(String.init)
            if let devIndex = tokens.firstIndex(of: "dev"), tokens.count > devIndex + 1 {
                return tokens[devIndex + 1]
            }
        }
        return nil
    }

    // MARK: Скрипт правил выхода (ТЗ раздел 7, шаг 4)

    /// Идемпотентный скрипт правил выхода. Имена интерфейсов/подсетей вшиты движком.
    public static func renderRulesScript(
        wanInterface: String,
        dockerSubnet: String,
        clientSubnet: String?
    ) -> String {
        let clientLines: String
        if let clientSubnet, !clientSubnet.isEmpty {
            clientLines = """
            iptables -t nat -C POSTROUTING -s '\(clientSubnet)' -o "$WAN" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s '\(clientSubnet)' -o "$WAN" -j MASQUERADE
            """
        } else {
            clientLines = "# клиентская подсеть не обнаружена — MASQUERADE только по Docker-подсети С1"
        }
        return """
        #!/usr/bin/env bash
        set -Eeuo pipefail
        # managed-by: amnezia-chain

        WAN='\(wanInterface)'
        DOCKER_SUBNET='\(dockerSubnet)'

        sysctl -w net.ipv4.ip_forward=1
        mkdir -p /etc/sysctl.d
        if [ -f /etc/sysctl.d/99-vpn-chain.conf ]; then cp -f /etc/sysctl.d/99-vpn-chain.conf "/etc/sysctl.d/99-vpn-chain.conf.bak.$(date +%s)"; fi
        cat > /etc/sysctl.d/99-vpn-chain.conf <<'VPNCHAIN_EOF'
        # managed-by: amnezia-chain
        net.ipv4.ip_forward = 1
        VPNCHAIN_EOF

        # SSH не блокируется: только добавляем разрешения
        iptables -C INPUT -p udp --dport 51828 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport 51828 -j ACCEPT
        iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        iptables -C FORWARD -i awg-relay -o "$WAN" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg-relay -o "$WAN" -j ACCEPT
        iptables -C FORWARD -i "$WAN" -o awg-relay -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WAN" -o awg-relay -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        iptables -t nat -C POSTROUTING -s "$DOCKER_SUBNET" -o "$WAN" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$DOCKER_SUBNET" -o "$WAN" -j MASQUERADE
        \(clientLines)
        # Регрессия приёмки: Docker на С1 делает SNAT клиентского трафика в адрес туннеля
        # (10.99.0.1), и без этого правила он уходил в интернет с частным источником —
        # ответы не возвращались, интернета у клиента не было.
        iptables -t nat -C POSTROUTING -s 10.99.0.0/24 -o "$WAN" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o "$WAN" -j MASQUERADE

        echo "vpn-chain: правила выхода применены"
        """
    }

    /// Юнит персистентности `vpn-chain-exit.service` (ТЗ раздел 7, шаг 5).
    public static let exitUnitTemplate: String = """
    [Unit]
    Description=Amnezia chain exit: NAT/FORWARD rules for awg-relay
    After=network-online.target awg-quick@awg-relay.service
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=\(rulesScriptPath)
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    """

    /// Установка скрипта правил и юнита, запуск применения правил (restart: переприменяется
    /// гарантированно, даже если юнит уже активен — регрессия приёмки).
    public static func installRulesCommand(
        wanInterface: String,
        dockerSubnet: String,
        clientSubnet: String?
    ) -> String {
        let scriptDelivery = FileDelivery.command(
            path: rulesScriptPath,
            content: renderRulesScript(wanInterface: wanInterface, dockerSubnet: dockerSubnet, clientSubnet: clientSubnet),
            mode: "0755"
        )
        let unitDelivery = FileDelivery.command(path: unitPath, content: exitUnitTemplate, mode: "0644")
        return """
        \(scriptDelivery)
        \(unitDelivery)
        systemctl daemon-reload
        systemctl enable vpn-chain-exit.service
        systemctl restart vpn-chain-exit.service
        """
    }

    // MARK: Действия шага «Configure C2»

    public static func actions(
        configContent: String,
        wanInterface: String,
        dockerSubnet: String,
        clientSubnet: String?
    ) -> [ShellAction] {
        [
            ShellAction(
                id: "c2-config",
                title: "Конфиг awg-relay (шаблон ТЗ 9.2)",
                check: nil,
                apply: FileDelivery.command(
                    path: "/etc/amnezia/amneziawg/awg-relay.conf",
                    content: configContent
                ),
                timeout: 60
            ),
            ShellAction(
                id: "c2-preclean",
                title: "Очистка остатков перед включением relay",
                check: nil,
                apply: preCleanCommand(dockerSubnet: dockerSubnet, clientSubnet: clientSubnet),
                timeout: 60
            ),
            ShellAction(
                id: "c2-subnet-collision",
                title: "Проверка коллизии подсетей на сервере-выходе",
                check: nil,
                apply: collisionCheckCommand(dockerSubnet: dockerSubnet),
                timeout: 60
            ),
            ShellAction(
                id: "c2-enable-relay",
                title: "Включение awg-quick@awg-relay",
                check: nil,
                apply: SystemdUnits.enableRelayCommand(),
                timeout: 60
            ),
            ShellAction(
                id: "c2-rules",
                title: "Правила выхода: INPUT/MSS/FORWARD/MASQUERADE + юнит vpn-chain-exit",
                check: nil,
                apply: installRulesCommand(wanInterface: wanInterface, dockerSubnet: dockerSubnet, clientSubnet: clientSubnet),
                timeout: 120
            ),
        ]
    }

    /// Снимаем остатки прошлых попыток: интерфейс и его маршруты.
    /// Удаляем только маршруты с `dev awg-relay` — чужие сети не трогаем.
    public static func preCleanCommand(dockerSubnet: String, clientSubnet: String?) -> String {
        var lines = [
            "awg-quick down awg-relay 2>/dev/null || true",
            "ip link del awg-relay type amneziawg 2>/dev/null || true",
            "ip link del awg-relay 2>/dev/null || true",
            "ip route del '\(dockerSubnet)' dev awg-relay 2>/dev/null || true",
            "ip route del '10.99.0.0/24' dev awg-relay 2>/dev/null || true",
        ]
        if let clientSubnet, !clientSubnet.isEmpty {
            lines.append("ip route del '\(clientSubnet)' dev awg-relay 2>/dev/null || true")
        }
        return lines.joined(separator: "\n")
    }

    /// Коллизия: на С2 уже есть маршрут в Docker-подсеть С1 не через awg-relay.
    /// Схема с таким перекрытием работать не будет — нужна перенумерация на одной из сторон.
    public static func collisionCheckCommand(dockerSubnet: String) -> String {
        """
        if ip route show | grep -F '\(dockerSubnet)' | grep -vF 'dev awg-relay' >/dev/null 2>&1; then
          echo "КОЛЛИЗИЯ ПОДСЕТЕЙ: на сервере-выходе уже есть маршрут в \(dockerSubnet) (совпадает с Docker-подсетью сервера-входа)."
          echo "Перенумеруйте Docker-сеть на одном из серверов (например, задайте другой default-address-pool) и повторите установку."
          exit 1
        fi
        """
    }
}
