import Foundation

/// Шаги конфигурации Сервера 1 — вход (задачи 5.2 и 5.3, ТЗ раздел 6.2).
public enum ConfigureC1 {
    public static let rulesScriptPath = "/usr/local/bin/vpn-chain-rules.sh"
    public static let serviceUnitPath = "/etc/systemd/system/vpn-chain.service"
    /// Номер таблицы policy routing и метрика blackhole (ТЗ 2.1, 6.2 шаг 8).
    public static let routingTable = 51821
    public static let blackholeMetric = 42760
    /// Метка «клиентский трафик → в relay-туннель» (fwmark).
    public static let mark = "0x51"

    // MARK: Скрипт правил С1 (ТЗ 6.2 шаг 8 + исправления из design.md D7)

    /// Правила С1.
    ///
    /// Регрессия приёмки 2026-11: правило `ip rule iif <интерфейс>` ломало подключение
    /// клиентов — интерфейс контейнера (`amn0`) используется в ОБА направления, и ответы
    /// контейнера клиенту (UDP `clientPort`) уходили в relay-туннель вместо клиента.
    /// Поэтому отбор трафика — по метке: маркируется только внутренний трафик, а ответы
    /// клиентской VPN-сессии исключаются по порту источника.
    public static func renderRulesScript(bridge: String, clientPort: String) -> String {
        """
        #!/usr/bin/env bash
        set -Eeuo pipefail
        # managed-by: amnezia-chain

        BRIDGE='\(bridge)'
        CLIENT_PORT='\(clientPort)'
        MARK=\(mark)

        sysctl -w net.ipv4.ip_forward=1
        mkdir -p /etc/sysctl.d
        if [ -f /etc/sysctl.d/99-vpn-chain.conf ]; then cp -f /etc/sysctl.d/99-vpn-chain.conf "/etc/sysctl.d/99-vpn-chain.conf.bak.$(date +%s)"; fi
        cat > /etc/sysctl.d/99-vpn-chain.conf <<'VPNCHAIN_EOF'
        # managed-by: amnezia-chain
        net.ipv4.ip_forward = 1
        net.ipv4.conf.default.rp_filter = 2
        VPNCHAIN_EOF

        # Снимаем все прежние правила нашей таблицы: схема отбора могла измениться между
        # прогонами (раньше — iif, теперь — fwmark), старое правило иначе осталось бы висеть.
        while ip rule del table \(routingTable) 2>/dev/null; do :; done

        # Отбор трафика: маркируем ТОЛЬКО внутренний трафик из контейнера приложения.
        # Ответы контейнера клиентам (sport = порт клиентского AWG) не маркируются —
        # иначе handshake клиента не завершается.
        iptables -t mangle -N VPNCHAIN_MARK 2>/dev/null || true
        iptables -t mangle -F VPNCHAIN_MARK
        iptables -t mangle -A VPNCHAIN_MARK -i "$BRIDGE" -p udp --sport "$CLIENT_PORT" -j RETURN
        iptables -t mangle -A VPNCHAIN_MARK -i "$BRIDGE" -p tcp --sport "$CLIENT_PORT" -j RETURN
        iptables -t mangle -A VPNCHAIN_MARK -i "$BRIDGE" -j MARK --set-mark "$MARK"
        iptables -t mangle -C PREROUTING -j VPNCHAIN_MARK 2>/dev/null || iptables -t mangle -I PREROUTING 1 -j VPNCHAIN_MARK

        ip rule add fwmark "$MARK" table \(routingTable) priority 100
        ip route replace default dev awg-relay table \(routingTable)
        ip route replace blackhole default table \(routingTable) metric \(blackholeMetric)

        # Регрессия приёмки: Docker NAT-ит клиентский трафик (-s 172.29.172.0/24 ! -o amn0),
        # и до С2 он доходил с частным источником 10.99.0.1 — интернет не отвечал.
        # Отключаем SNAT для всего, что уходит в relay-туннель (правило перед Docker'ом).
        iptables -t nat -C POSTROUTING -o awg-relay -j RETURN 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o awg-relay -j RETURN

        # rp_filter: ядро берёт max(all, iface) — выставляем и на интерфейсе awg-relay,
        # иначе строгий фильтр интерфейса резал бы ответы из туннеля.
        sysctl -w net.ipv4.conf.all.rp_filter=2
        sysctl -w net.ipv4.conf.awg-relay.rp_filter=2 2>/dev/null || true

        # Firewall: только через DOCKER-USER (санкционированное Docker место).
        if iptables -S DOCKER-USER >/dev/null 2>&1; then
          BASE_CHAIN=DOCKER-USER
        else
          echo "vpn-chain: предупреждение: DOCKER-USER не найдена, правила добавляются в FORWARD" >&2
          BASE_CHAIN=FORWARD
        fi
        if ip6tables -S DOCKER-USER >/dev/null 2>&1; then
          BASE_CHAIN6=DOCKER-USER
        else
          BASE_CHAIN6=FORWARD
        fi

        iptables -N VPNCHAIN 2>/dev/null || true
        iptables -C "$BASE_CHAIN" -j VPNCHAIN 2>/dev/null || iptables -I "$BASE_CHAIN" 1 -j VPNCHAIN
        iptables -F VPNCHAIN
        iptables -A VPNCHAIN -i "$BRIDGE" -o awg-relay -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        iptables -A VPNCHAIN -i "$BRIDGE" -o awg-relay -j ACCEPT
        iptables -A VPNCHAIN -i awg-relay -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

        # Анти-утечка IPv6 клиентов (ответы клиентской VPN-сессии не блокируем).
        ip6tables -N VPNCHAIN6 2>/dev/null || true
        ip6tables -C "$BASE_CHAIN6" -j VPNCHAIN6 2>/dev/null || ip6tables -I "$BASE_CHAIN6" 1 -j VPNCHAIN6
        ip6tables -F VPNCHAIN6
        ip6tables -A VPNCHAIN6 -i "$BRIDGE" -p udp --sport "$CLIENT_PORT" -j RETURN
        ip6tables -A VPNCHAIN6 -i "$BRIDGE" -p tcp --sport "$CLIENT_PORT" -j RETURN
        ip6tables -A VPNCHAIN6 -i "$BRIDGE" -j DROP

        echo "vpn-chain: policy routing применён"
        """
    }

    /// Юнит `vpn-chain.service` (ТЗ 9.3).
    public static let serviceUnitTemplate: String = """
    [Unit]
    Description=Amnezia chain: policy routing for AWG relay
    After=docker.service awg-quick@awg-relay.service network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=\(rulesScriptPath)
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    """

    /// Установка скрипта правил и юнита, запуск применения правил (restart).
    public static func installRulesCommand(bridge: String, clientPort: String) -> String {
        let scriptDelivery = FileDelivery.command(
            path: rulesScriptPath,
            content: renderRulesScript(bridge: bridge, clientPort: clientPort),
            mode: "0755"
        )
        let unitDelivery = FileDelivery.command(path: serviceUnitPath, content: serviceUnitTemplate, mode: "0644")
        return """
        \(scriptDelivery)
        \(unitDelivery)
        systemctl daemon-reload
        systemctl enable vpn-chain.service
        systemctl restart vpn-chain.service
        """
    }

    // MARK: Действия шага «Configure C1»

    public static func actions(configContent: String, bridge: String, clientPort: String) -> [ShellAction] {
        [
            ShellAction(
                id: "c1-config",
                title: "Конфиг awg-relay (шаблон ТЗ 9.1, Table = off)",
                check: nil,
                apply: FileDelivery.command(
                    path: "/etc/amnezia/amneziawg/awg-relay.conf",
                    content: configContent
                ),
                timeout: 60
            ),
            ShellAction(
                id: "c1-awgquick-unit",
                title: "Юнит awg-quick@.service (если отсутствует)",
                check: nil,
                apply: SystemdUnits.installAwgQuickUnitCommand(),
                timeout: 60
            ),
            ShellAction(
                id: "c1-enable-relay",
                title: "Включение awg-quick@awg-relay",
                check: nil,
                apply: SystemdUnits.enableRelayCommand(),
                timeout: 60
            ),
            ShellAction(
                id: "c1-rules",
                title: "Policy routing по метке + исключение ответов клиентам + blackhole kill-switch + DOCKER-USER + юнит vpn-chain",
                check: nil,
                apply: installRulesCommand(bridge: bridge, clientPort: clientPort),
                timeout: 120
            ),
        ]
    }
}
