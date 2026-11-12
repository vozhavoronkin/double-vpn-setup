import Foundation

/// Статус relay-интерфейса из `awg show awg-relay` (задача 6.1).
public struct RelayStatus: Sendable, Equatable {
    public let interfaceUp: Bool
    /// Возраст последнего handshake в секундах (nil — handshake не было).
    public let handshakeSecondsAgo: Int?
    public let rxBytes: Int64?
    public let txBytes: Int64?
}

/// Парсеры состояния цепочки — чистые функции, покрываются unit-тестами на фиксчунах.
public enum StatusParsers {
    // MARK: Команды

    public static let awgShowCommand = "awg show awg-relay"
    public static let ipRuleCommand = "ip rule show"
    public static let routeTableCommand = "ip route show table 51821"
    public static let dockerUserCommand = "iptables -S DOCKER-USER"
    public static let natCommand = "iptables -t nat -S POSTROUTING"
    public static let listeningCommand = "ss -uln"

    public static func containerAliveCommand(container: String) -> String {
        "docker exec \(container) awg show 2>/dev/null"
    }

    /// Чтение файла окружения для диагностических проверок.
    public static let environmentCommand = "cat /etc/amnezia/chain/env 2>/dev/null"

    // MARK: awg show

    public static func parseRelayStatus(_ output: String) -> RelayStatus {
        let interfaceUp = output.contains("interface: awg-relay")
        var handshake: Int?
        var rx: Int64?
        var tx: Int64?
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("latest handshake:") {
                handshake = parseHandshakeAge(String(trimmed.dropFirst("latest handshake:".count)))
            } else if trimmed.hasPrefix("transfer:") {
                let parsed = parseTransfer(String(trimmed.dropFirst("transfer:".count)))
                rx = parsed?.rx
                tx = parsed?.tx
            }
        }
        return RelayStatus(
            interfaceUp: interfaceUp, handshakeSecondsAgo: handshake, rxBytes: rx, txBytes: tx)
    }

    /// «47 seconds ago», «2 minutes, 3 seconds ago», «1 hour, 5 minutes ago», «3 days, 4 hours ago» → секунды.
    public static func parseHandshakeAge(_ text: String) -> Int? {
        var value = text.trimmingCharacters(in: .whitespaces)
        guard value.hasSuffix("ago") else { return nil }
        value.removeLast(3)
        value = value.trimmingCharacters(in: .whitespaces)
        var total = 0
        for part in value.components(separatedBy: ",") {
            let tokens = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard tokens.count == 2, let amount = Int(tokens[0]) else { return nil }
            let unit = tokens[1].lowercased()
            let seconds: Int
            switch unit {
            case "second", "seconds": seconds = 1
            case "minute", "minutes": seconds = 60
            case "hour", "hours": seconds = 3600
            case "day", "days": seconds = 86_400
            default: return nil
            }
            total += amount * seconds
        }
        return total
    }

    /// «1.2 MiB received, 980 KiB sent» → (rx, tx) в байтах.
    public static func parseTransfer(_ text: String) -> (rx: Int64, tx: Int64)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: "received,").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return nil }
        guard let rx = parseBytes(parts[0].replacingOccurrences(of: "received", with: "")),
            let tx = parseBytes(parts[1].replacingOccurrences(of: "sent", with: ""))
        else {
            return nil
        }
        return (rx, tx)
    }

    private static func parseBytes(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let tokens = trimmed.split(separator: " ")
        guard tokens.count == 2, let value = Double(tokens[0]) else { return nil }
        let unit = tokens[1].uppercased()
        let multiplier: Double
        switch unit {
        case "B": multiplier = 1
        case "KIB": multiplier = 1024
        case "MIB": multiplier = 1024 * 1024
        case "GIB": multiplier = 1024 * 1024 * 1024
        case "TIB": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(value * multiplier)
    }

    // MARK: ip rule / route table / chains

    /// Есть ли правило policy routing для клиентского трафика (`fwmark …` / `iif …` lookup 51821).
    public static func parseIpRule(_ output: String) -> Bool {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("fwmark") || trimmed.contains("iif"),
                trimmed.contains("lookup 51821")
            {
                return true
            }
        }
        return false
    }

    /// Таблица 51821: default через awg-relay и blackhole kill-switch.
    public static func parseRouteTable(_ output: String) -> (defaultViaRelay: Bool, blackhole: Bool)
    {
        let hasRelay = output.contains("default dev awg-relay")
        let hasBlackhole = output.contains("blackhole default")
        return (defaultViaRelay: hasRelay, blackhole: hasBlackhole)
    }

    /// Правила цепочки С1 подключены в DOCKER-USER (или fallback FORWARD).
    public static func parseDockerUserJump(_ output: String) -> Bool {
        output.contains("-j VPNCHAIN")
    }

    /// Порт 51828 слушается (вывод `ss -uln`).
    public static func parseListeningPort(_ output: String, port: UInt16 = 51828) -> Bool {
        output.contains(":\(port) ")
    }

    /// MASQUERADE для подсети присутствует в POSTROUTING.
    public static func parseMasquerade(_ output: String, subnet: String) -> Bool {
        output.contains("-s \(subnet)") && output.contains("MASQUERADE")
    }

    /// Есть ли у конфига С2 клиентская подсеть в AllowedIPs/MASQUERADE.
    public static func parseConfigAllowedIPs(_ config: String) -> String? {
        for line in config.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("AllowedIPs") {
                return trimmed
            }
        }
        return nil
    }
}

// MARK: Снапшот состояния

/// Доступность сервера: «нет связи» отделена от «цепочка сломана» (спека chain-diagnostics).
public enum ServerAvailability<Payload: Sendable>: Sendable {
    case unreachable(reason: String)
    case available(Payload)
}

/// Состояние сервера-входа.
public struct EntryServerStatus: Sendable {
    public var relay: RelayStatus?
    public var policyRulePresent: Bool?
    public var routeKillSwitch: (defaultViaRelay: Bool, blackhole: Bool)?
    public var dockerUserJump: Bool?
    public var containerAlive: Bool?
}

/// Состояние сервера-выхода.
public struct ExitServerStatus: Sendable {
    public var relay: RelayStatus?
    public var portListening: Bool?
    public var masqueradeForDockerSubnet: Bool?
}

/// Полный снапшот цепочки.
public struct ChainStatusSnapshot: Sendable {
    public let entry: ServerAvailability<EntryServerStatus>
    public let exit: ServerAvailability<ExitServerStatus>
}

/// Сбор снапшота с обоих серверов (задача 6.1).
public struct StatusCollector: Sendable {
    private let environment: ChainState.Environment?

    public init(environment: ChainState.Environment?) {
        self.environment = environment
    }

    public func snapshot(c1: (any RemoteRunner)?, c2: any RemoteRunner) async -> ChainStatusSnapshot
    {
        async let entryStatus: ServerAvailability<EntryServerStatus> = collectEntry(c1)
        async let exitStatus: ServerAvailability<ExitServerStatus> = collectExit(c2)
        return await ChainStatusSnapshot(entry: entryStatus, exit: exitStatus)
    }

    private func collectEntry(_ runner: (any RemoteRunner)?) async -> ServerAvailability<
        EntryServerStatus
    > {
        guard let runner else { return .unreachable(reason: "профиль сервера-входа не настроен") }
        guard
            let relayResult = try? await runner.run(
                StatusParsers.awgShowCommand, timeout: 30, onOutput: nil)
        else {
            return .unreachable(reason: "SSH-соединение не установлено")
        }
        guard relayResult.succeeded else {
            return .unreachable(
                reason: relayResult.stderr.isEmpty
                    ? "сервер доступен, но awg show завершился ошибкой" : relayResult.stderr)
        }
        var status = EntryServerStatus()
        status.relay = StatusParsers.parseRelayStatus(relayResult.stdout)
        if let rule = try? await runner.run(StatusParsers.ipRuleCommand, timeout: 30, onOutput: nil)
        {
            status.policyRulePresent = StatusParsers.parseIpRule(rule.stdout)
        }
        if let route = try? await runner.run(
            StatusParsers.routeTableCommand, timeout: 30, onOutput: nil)
        {
            status.routeKillSwitch = StatusParsers.parseRouteTable(route.stdout)
        }
        if let dockerUser = try? await runner.run(
            StatusParsers.dockerUserCommand, timeout: 30, onOutput: nil)
        {
            status.dockerUserJump = StatusParsers.parseDockerUserJump(dockerUser.stdout)
        }
        if let containerName = environment?.containerName, !containerName.isEmpty,
            let alive = try? await runner.run(
                StatusParsers.containerAliveCommand(container: containerName), timeout: 30,
                onOutput: nil)
        {
            status.containerAlive = alive.succeeded
        }
        return .available(status)
    }

    private func collectExit(_ runner: any RemoteRunner) async -> ServerAvailability<
        ExitServerStatus
    > {
        guard
            let relayResult = try? await runner.run(
                StatusParsers.awgShowCommand, timeout: 30, onOutput: nil)
        else {
            return .unreachable(reason: "SSH-соединение не установлено")
        }
        guard relayResult.succeeded else {
            return .unreachable(
                reason: relayResult.stderr.isEmpty
                    ? "сервер доступен, но awg show завершился ошибкой" : relayResult.stderr)
        }
        var status = ExitServerStatus()
        status.relay = StatusParsers.parseRelayStatus(relayResult.stdout)
        if let listening = try? await runner.run(
            StatusParsers.listeningCommand, timeout: 30, onOutput: nil)
        {
            status.portListening = StatusParsers.parseListeningPort(listening.stdout)
        }
        if let subnet = environment?.dockerSubnet,
            let nat = try? await runner.run(StatusParsers.natCommand, timeout: 30, onOutput: nil)
        {
            status.masqueradeForDockerSubnet = StatusParsers.parseMasquerade(
                nat.stdout, subnet: subnet)
        }
        return .available(status)
    }
}
