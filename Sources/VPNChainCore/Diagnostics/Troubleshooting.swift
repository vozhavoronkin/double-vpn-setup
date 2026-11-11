import Foundation

/// Симптомы из таблицы troubleshooting ТЗ (раздел 11).
public enum Symptom: String, CaseIterable, Sendable {
    case noHandshake
    case handshakeButNoInternet
    case brokenAfterAppUserAdded
    case dockerNetworkRecreated
    case sshLost
    case slowSpeed
    case ipv6Leak
}

/// Гайд по симптому: автоматические проверки + советы (design D8 — данные, не код).
public struct SymptomGuide: Sendable {
    public let symptom: Symptom
    public let title: String
    public let explanation: String
    /// Проверки выполняются автоматически (на сервере из `check.server`).
    public let checks: [ServerCheck]
    /// Советы пользователю по порядку действий.
    public let advice: [String]
    /// Показать кнопку «переприменить установку» (обновит конфиг С2).
    public let suggestsReapply: Bool
}

/// Сборка гайдов по симптому на основе окружения С1 и адреса сервера-выхода.
public enum Troubleshooting {
    public static func guide(
        for symptom: Symptom,
        environment: ChainState.Environment?,
        s2Address: String?
    ) -> SymptomGuide {
        switch symptom {
        case .noHandshake:
            return noHandshakeGuide(s2Address: s2Address, symptom: symptom)
        case .handshakeButNoInternet:
            return handshakeButNoInternetGuide(environment: environment, symptom: symptom)
        case .brokenAfterAppUserAdded:
            return SymptomGuide(
                symptom: symptom,
                title: "Сломалось после добавления пользователя в приложении",
                explanation: "Приложение AmneziaVPN переписало конфиг контейнера при добавлении пользователя.",
                checks: [],
                advice: [
                    "Это ожидаемое поведение — host-level relay от него не зависит, ничего делать не нужно.",
                    "Если клиенты всё же не работают — перепримените конфигурацию (см. «Установка»).",
                ],
                suggestsReapply: false
            )
        case .dockerNetworkRecreated:
            return SymptomGuide(
                symptom: symptom,
                title: "Docker-сеть пересоздана (новая подсеть)",
                explanation: "У сервера-выхода устарели AllowedIPs и MASQUERADE.",
                checks: environment.map { env in
                    [
                        ServerCheck(
                            id: "subnet-match",
                            title: "Подсеть в AllowedIPs С2 соответствует текущей",
                            command: "cat /etc/amnezia/amneziawg/awg-relay.conf",
                            kind: .outputContains(env.dockerSubnet),
                            failureHint: "В конфиге С2 устаревшая подсеть — перепримените установку",
                            server: .exit
                        ),
                    ]
                } ?? [],
                advice: [
                    "Перепримените установку: движок заново детектирует подсеть и обновит конфиг сервера-выхода.",
                ],
                suggestsReapply: true
            )
        case .sshLost:
            let rescue = "while ip rule del table 51821 2>/dev/null; do :; done"
            return SymptomGuide(
                symptom: symptom,
                title: "Пропал SSH на сервере-входе",
                explanation: "Ошибка в policy routing: правило затронуло host-трафик. Такого быть не должно — тоннелируется только трафик с меткой клиентских соединений.",
                checks: [],
                advice: [
                    "Через консоль провайдера выполните: \(rescue)",
                    "После восстановления SSH сообщите об ошибке — приложению нужна конфигурация, не задевающая host-трафик.",
                ],
                suggestsReapply: false
            )
        case .slowSpeed:
            return SymptomGuide(
                symptom: symptom,
                title: "Работает, но медленно",
                explanation: "Userspace-реализация (норма) или MTU при двойной инкапсуляции.",
                checks: [],
                advice: [
                    "Предупреждение «Missing kernel module. Falling back to slow userspace» в логе — норма, не ошибка.",
                    "В приложении снизьте MTU до 1380 (помогает UDP-приложениям; TCP подстраивается через MSS clamp).",
                    "Для нагруженных серверов — ядерный модуль из PPA (раздел 12.1 ТЗ, отдельная итерация).",
                    "Проверьте awg show awg-relay: нет ли постоянных новых handshake.",
                ],
                suggestsReapply: false
            )
        case .ipv6Leak:
            return SymptomGuide(
                symptom: symptom,
                title: "IPv6-утечка у клиента",
                explanation: "Правило VPNCHAIN6 не применилось или Docker пересоздал DOCKER-USER.",
                checks: [
                    ServerCheck(
                        id: "ipv6-rule",
                        title: "VPNCHAIN6 подключена в ip6tables",
                        command: "ip6tables -S DOCKER-USER 2>/dev/null || ip6tables -S FORWARD",
                        kind: .outputContains("VPNCHAIN6"),
                        failureHint: "Правило не на месте — перезапустите vpn-chain.service на сервере-входе",
                        server: .entry
                    ),
                ],
                advice: [
                    "Перезапустите vpn-chain.service на сервере-входе: systemctl restart vpn-chain.service",
                ],
                suggestsReapply: false
            )
        }
    }

    // MARK: Частные гайды

    private static func noHandshakeGuide(s2Address: String?, symptom: Symptom) -> SymptomGuide {
        var checks: [ServerCheck] = [
            ServerCheck(
                id: "obf-entry",
                title: "Параметры обфускации на сервере-входе",
                command: "awg showconf awg-relay",
                kind: .outputContainsAll(["S1 =", "S2 =", "H1 ="]),
                failureHint: "Конфиг relay не содержит параметров обфускации — перепримените конфигурацию",
                server: .entry
            ),
        ]
        if let s2Address, !s2Address.isEmpty {
            checks.insert(
                ServerCheck(
                    id: "udp-reachable",
                    title: "UDP 51828 достижим с сервера-входа",
                    command: "nc -uvz -w 3 \(s2Address) 51828 >/dev/null 2>&1",
                    kind: .exitCodeZero,
                    failureHint: "Порт закрыт: откройте UDP 51828 в firewall/cloud-панели провайдера сервера-выхода (ufw allow 51828/udp)",
                    server: .entry
                ),
                at: 0
            )
        }
        return SymptomGuide(
            symptom: symptom,
            title: "Нет handshake между серверами",
            explanation: "Порядок диагностики: порт → параметры обфускации → версия сборки.",
            checks: checks,
            advice: [
                "1. Откройте UDP 51828 в firewall/cloud-группе провайдера сервера-выхода (ufw allow 51828/udp).",
                "2. Сравните `awg showconf awg-relay` на обоих серверах: S1/S2/H1–H4 обязаны совпадать.",
                "3. Убедитесь, что оба сервера собраны из одного commit (раздел 3.2 ТЗ); иначе пересоберите.",
                "4. Перезапустите relay на обоих: systemctl restart awg-quick@awg-relay.",
            ],
            suggestsReapply: false
        )
    }

    private static func handshakeButNoInternetGuide(environment: ChainState.Environment?, symptom: Symptom) -> SymptomGuide {
        var allowedIPsCheck = ServerCheck(
            id: "allowed-ips",
            title: "AllowedIPs пира содержит подсети сервера-входа",
            command: "cat /etc/amnezia/amneziawg/awg-relay.conf",
            kind: .outputContains("AllowedIPs = 10.99.0.0/24"),
            failureHint: "В AllowedIPs пира нет Docker-подсети сервера-входа — перепримените конфигурацию",
            server: .exit
        )
        if let dockerSubnet = environment?.dockerSubnet {
            allowedIPsCheck = ServerCheck(
                id: "allowed-ips",
                title: "AllowedIPs пира содержит подсети сервера-входа",
                command: "cat /etc/amnezia/amneziawg/awg-relay.conf",
                kind: .outputContains(dockerSubnet),
                failureHint: "В AllowedIPs пира нет Docker-подсети \(dockerSubnet) — перепримените конфигурацию",
                server: .exit
            )
        }
        return SymptomGuide(
            symptom: symptom,
            title: "Handshake есть, интернета нет",
            explanation: "Порядок диагностики: ip_forward → MASQUERADE → AllowedIPs → правила С1.",
            checks: [
                ServerCheck(
                    id: "ip-forward",
                    title: "ip_forward включён на сервере-выходе",
                    command: "sysctl -n net.ipv4.ip_forward",
                    kind: .outputContains("1"),
                    failureHint: "ip_forward выключен — выполните sysctl -w net.ipv4.ip_forward=1 и проверьте юнит vpn-chain-exit",
                    server: .exit
                ),
                ServerCheck(
                    id: "nat-present",
                    title: "MASQUERADE присутствует на сервере-выходе",
                    command: StatusParsers.natCommand,
                    kind: .outputContains("MASQUERADE"),
                    failureHint: "MASQUERADE отсутствует — перезапустите vpn-chain-exit.service",
                    server: .exit
                ),
                allowedIPsCheck,
                ServerCheck(
                    id: "c1-rules",
                    title: "Policy routing на сервере-входе на месте",
                    command: StatusParsers.ipRuleCommand,
                    kind: .outputContains("lookup 51821"),
                    failureHint: "Правила потеряны — systemctl restart vpn-chain.service",
                    server: .entry
                ),
            ],
            advice: [
                "1. Проверьте перечисленные пункты — результат каждой проверки ниже.",
                "2. Если крупный UDP не проходит — снизьте MTU клиента до 1380 (раздел 8 ТЗ).",
            ],
            suggestsReapply: false
        )
    }
}
