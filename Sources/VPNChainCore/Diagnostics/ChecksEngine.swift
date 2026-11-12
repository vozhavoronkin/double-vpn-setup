import Foundation

/// Декларативная проверка приёмки (design D8: диагностика как данные).
public struct ServerCheck: Sendable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case exitCodeZero
        case outputContains(String)
        case outputContainsAll([String])
        /// Вывод — `awg show`: handshake не старше N секунд.
        case handshakeWithin(seconds: Int)
    }

    public let id: String
    public let title: String
    public let command: String
    public let kind: Kind
    /// Подсказка при провале (таблицы разделов 10/11 ТЗ).
    public let failureHint: String
    public let server: ServerRole

    public init(
        id: String,
        title: String,
        command: String,
        kind: Kind,
        failureHint: String,
        server: ServerRole
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.kind = kind
        self.failureHint = failureHint
        self.server = server
    }
}

/// Результат проверки.
public struct CheckResult: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let passed: Bool
    /// nil при успехе; при провале — подсказка из раздела 11 ТЗ.
    public let hint: String?

    public init(id: String, title: String, passed: Bool, hint: String?) {
        self.id = id
        self.title = title
        self.passed = passed
        self.hint = hint
    }
}

/// Движок проверок (задача 6.2): выполняет декларативные проверки на нужном сервере.
public enum ChecksEngine {
    /// Чистая оценка результата команды.
    public static func evaluate(_ check: ServerCheck, result: SSHExecResult) -> (
        passed: Bool, hint: String?
    ) {
        switch check.kind {
        case .exitCodeZero:
            return (result.exitCode == 0, result.exitCode == 0 ? nil : check.failureHint)
        case .outputContains(let needle):
            return (
                result.stdout.contains(needle),
                result.stdout.contains(needle) ? nil : check.failureHint
            )
        case .outputContainsAll(let needles):
            let passed = needles.allSatisfy { result.stdout.contains($0) }
            return (passed, passed ? nil : check.failureHint)
        case .handshakeWithin(let maxSeconds):
            let status = StatusParsers.parseRelayStatus(result.stdout)
            if let age = status.handshakeSecondsAgo {
                let passed = age <= maxSeconds
                return (passed, passed ? nil : "\(check.failureHint) (handshake \(age) c назад)")
            }
            return (false, "\(check.failureHint) (handshake не зафиксирован)")
        }
    }

    /// Выполняет проверки на соответствующих серверах; каждая изолирована — сбой не рвёт остальные.
    public static func runAll(
        _ checks: [ServerCheck],
        entry: (any RemoteRunner)?,
        exit: (any RemoteRunner)?,
        timeout: TimeInterval = 30
    ) async -> [CheckResult] {
        var results: [CheckResult] = []
        for check in checks {
            let runner: (any RemoteRunner)? = check.server == .entry ? entry : exit
            guard let runner else {
                results.append(
                    CheckResult(
                        id: check.id, title: check.title, passed: false, hint: "сервер недоступен"))
                continue
            }
            do {
                let result = try await runner.run(check.command, timeout: timeout, onOutput: nil)
                let evaluation = evaluate(check, result: result)
                results.append(
                    CheckResult(
                        id: check.id, title: check.title, passed: evaluation.passed,
                        hint: evaluation.hint))
            } catch {
                results.append(
                    CheckResult(
                        id: check.id, title: check.title, passed: false,
                        hint: "\(check.failureHint) (команда не выполнена: \(error))"))
            }
        }
        return results
    }

    // MARK: Набор автоматизируемых проверок (раздел 10 ТЗ)

    /// Проверки для настроенной цепочки; часть требует окружения С1 (env).
    public static func automatedChecks(environment: ChainState.Environment?) -> [ServerCheck] {
        var checks: [ServerCheck] = [
            ServerCheck(
                id: "handshake",
                title: "Handshake С1↔С2 не старше 2–3 минут",
                command: StatusParsers.awgShowCommand,
                kind: .handshakeWithin(seconds: 180),
                failureHint:
                    "Нет handshake: откройте UDP 51828 у провайдера сервера-выхода; сверьте S1/S2/H1–H4 (awg showconf awg-relay на обоих) и commit сборки",
                server: .entry
            ),
            ServerCheck(
                id: "policy-rule",
                title: "Policy routing: метка клиентского трафика → таблица 51821",
                command: StatusParsers.ipRuleCommand,
                kind: .outputContainsAll(["fwmark \(ConfigureC1.mark)", "lookup 51821"]),
                failureHint:
                    "Правило потеряно (после reboot Docker пересоздаёт правила) — перезапустите vpn-chain.service",
                server: .entry
            ),
            ServerCheck(
                id: "kill-switch",
                title: "Kill-switch: default через awg-relay + blackhole",
                command: StatusParsers.routeTableCommand,
                kind: .outputContainsAll(["default dev awg-relay", "blackhole default"]),
                failureHint: "Таблица 51821 не полная — перезапустите vpn-chain.service",
                server: .entry
            ),
            ServerCheck(
                id: "docker-user",
                title: "Цепочка VPNCHAIN подключена в DOCKER-USER",
                command: StatusParsers.dockerUserCommand,
                kind: .outputContains("-j VPNCHAIN"),
                failureHint: "Docker пересоздал цепочки — перезапустите vpn-chain.service",
                server: .entry
            ),
            ServerCheck(
                id: "entry-nat",
                title: "SNAT отключён для трафика в relay-туннель",
                command: StatusParsers.natCommand,
                kind: .outputContains("-o awg-relay -j RETURN"),
                failureHint: "Docker NAT-ит туннельный трафик — перезапустите vpn-chain.service",
                server: .entry
            ),
            ServerCheck(
                id: "exit-relay",
                title: "Интерфейс awg-relay поднят на сервере-выходе",
                command: StatusParsers.awgShowCommand,
                kind: .outputContains("interface: awg-relay"),
                failureHint:
                    "Relay на сервере-выходе не поднят — проверьте systemctl status awg-quick@awg-relay",
                server: .exit
            ),
            ServerCheck(
                id: "exit-port",
                title: "Порт 51828/UDP слушается на сервере-выходе",
                command: StatusParsers.listeningCommand,
                kind: .outputContains(":51828 "),
                failureHint:
                    "Порт не слушается — проверьте конфиг awg-relay и systemctl status awg-quick@awg-relay",
                server: .exit
            ),
        ]

        if let environment {
            if let containerName = environment.containerName, !containerName.isEmpty {
                checks.append(
                    ServerCheck(
                        id: "container-untouched",
                        title: "Контейнер AmneziaVPN не затронут",
                        command: StatusParsers.containerAliveCommand(container: containerName),
                        kind: .exitCodeZero,
                        failureHint:
                            "Контейнер приложения не отвечает — relay не должен был его затронуть; проверьте docker ps",
                        server: .entry
                    )
                )
            }
            checks.append(
                ServerCheck(
                    id: "exit-nat",
                    title: "MASQUERADE по Docker-подсети сервера-входа",
                    command: StatusParsers.natCommand,
                    kind: .outputContains("-s \(environment.dockerSubnet)"),
                    failureHint:
                        "MASQUERADE отсутствует — перезапустите vpn-chain-exit.service на сервере-выходе",
                    server: .exit
                )
            )
        }
        return checks
    }
}

/// Ручные пункты чек-листа (ТЗ раздел 10: пункты 7–9, 11–12).
public struct ManualCheck: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let instruction: String

    public init(id: String, title: String, instruction: String) {
        self.id = id
        self.title = title
        self.instruction = instruction
    }
}

public enum ManualChecklist {
    public static let items: [ManualCheck] = [
        ManualCheck(
            id: "client-ip",
            title: "Внешний IP клиента",
            instruction:
                "Подключитесь в AmneziaVPN и откройте 2ip.ru / ifconfig.me — должен отображаться IP сервера-выхода."
        ),
        ManualCheck(
            id: "dns-leak",
            title: "Утечки DNS",
            instruction:
                "Откройте browserleaks.com/dns или dnsleaktest.com — резолвер один, из туннеля, без утечек."
        ),
        ManualCheck(
            id: "ipv6",
            title: "Утечки IPv6",
            instruction:
                "Откройте test-ipv6.com — IPv6 отсутствует или не течёт (правило VPNCHAIN6)."
        ),
        ManualCheck(
            id: "reboot",
            title: "Персистентность после reboot",
            instruction:
                "Перезагрузите оба сервера и повторите проверки — всё должно восстановиться само (юниты awg-quick@awg-relay и vpn-chain)."
        ),
        ManualCheck(
            id: "kill-switch",
            title: "Серверный kill-switch",
            instruction:
                "На сервере-входе: systemctl stop awg-quick@awg-relay → у клиента страницы не открываются и реальный IP не светится; systemctl start — снова работает."
        ),
    ]
}
