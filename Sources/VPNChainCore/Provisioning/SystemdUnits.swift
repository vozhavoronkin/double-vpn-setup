import Foundation

/// Рендер systemd-юнитов (задача 4.4, шаблон ТЗ 9.4).
public enum SystemdUnits {
    /// Юнит `awg-quick@.service` с userspace-fallback (ТЗ 9.4).
    /// Переменная `WG_QUICK_USERSPACE_IMPLEMENTATION` гарантирует запуск
    /// `amneziawg-go`, даже если бинарник вне стандартного PATH.
    public static let awgQuickTemplate: String = """
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
        """

    /// Команда установки юнита: создаётся ТОЛЬКО если отсутствует
    /// (`make install` amneziawg-tools обычно ставит свой юнит).
    public static func installAwgQuickUnitCommand() -> String {
        let delivery = FileDelivery.command(
            path: "/etc/systemd/system/awg-quick@.service",
            content: awgQuickTemplate,
            mode: "0644"
        )
        return """
            if [ ! -f /etc/systemd/system/awg-quick@.service ]; then
            \(delivery)
            systemctl daemon-reload
            fi
            """
    }

    /// Включение и ПЕРЕЗАПУСК relay-туннеля: `enable --now` для уже активного юнита —
    /// no-op, и новый конфиг/бинарник не вступили бы в силу без рестарта (регрессия приёмки).
    public static func enableRelayCommand() -> String {
        "systemctl enable awg-quick@awg-relay && systemctl restart awg-quick@awg-relay"
    }
}
