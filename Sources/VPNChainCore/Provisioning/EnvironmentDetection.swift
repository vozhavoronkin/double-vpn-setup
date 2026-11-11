import Foundation

/// Детект окружения AmneziaVPN на С1 (задача 4.1, ТЗ раздел 6.2 шаги 1–3):
/// контейнер → Docker-сеть/бридж/подсеть/IP контейнера → мягкий детект клиентской подсети.
///
/// Дополнительно (принятая доработка): если контейнер подключён к дефолтной сети
/// `bridge` (172.17.0.0/16 — она есть почти на любом сервере с Docker и коллидируется
/// с сетями сервера-выхода), движок автоматически переносит контейнер на выделенную
/// сеть `amnezia-relay-net` со свободной подсетью.
public struct EnvironmentDetector: Sendable {
    public struct DetectionResult: Sendable, Equatable {
        /// Имя контейнера из результата детекта (нигде не хардкодится — исправление к ТЗ).
        public let containerName: String
        public let environment: ChainState.Environment
        /// Контейнер был перенесён с дефолтного bridge на выделенную сеть.
        public let migratedFromDefaultBridge: Bool

        public init(containerName: String, environment: ChainState.Environment, migratedFromDefaultBridge: Bool = false) {
            self.containerName = containerName
            self.environment = environment
            self.migratedFromDefaultBridge = migratedFromDefaultBridge
        }
    }

    /// Выделенная сеть для relay-контейнера.
    public static let relayNetworkName = "amnezia-relay-net"

    private let runner: any RemoteRunner
    /// Сервер-выход: нужен для сбора занятых подсетей при выборе сети миграции.
    private let exitRoutesRunner: (any RemoteRunner)?

    public init(runner: any RemoteRunner, exitRoutesRunner: (any RemoteRunner)? = nil) {
        self.runner = runner
        self.exitRoutesRunner = exitRoutesRunner
    }

    // MARK: Команды (публичные для тестов фиксчунов)

    public static let listContainersCommand = "docker ps --format '{{.Names}}'"

    public static func containerNetworksCommand(container: String) -> String {
        "docker inspect -f '{{json .NetworkSettings.Networks}}' \(container)"
    }

    public static func networkInspectCommand(network: String) -> String {
        "docker network inspect -f '{{json .}}' \(network)"
    }

    /// Конфиг клиентского AWG внутри контейнера. Путь зависит от версии AmneziaVPN
    /// (`awg0.conf` в новых, `wg0.conf` в старых) — пробуем известные варианты.
    public static func clientSubnetCommand(container: String) -> String {
        "docker exec \(container) sh -c 'for f in /opt/amnezia/awg/awg0.conf /opt/amnezia/awg/wg0.conf /etc/amnezia/awg/awg0.conf /etc/amnezia/awg/wg0.conf; do if [ -f \"$f\" ]; then echo \"==FILE $f==\"; cat \"$f\"; fi; done'"
    }

    /// Порт клиентского AWG из конфига контейнера (`ListenPort`). Нужен, чтобы
    /// исключить ответы контейнера клиентам из relay-туннеля (регрессия приёмки:
    /// `iif` без исключения порта ломал handshake клиента).
    public static func parseClientPort(_ conf: String) -> String? {
        for line in conf.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ListenPort") else { continue }
            let value = trimmed.split(separator: "=", maxSplits: 1).dropFirst().first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if let port = Int(value), (1...65535).contains(port) { return String(port) }
        }
        return nil
    }

    public static let routesCommand = "ip -4 route show"

    /// Список интерфейсов с IPv4-адресами (одна строка на адрес).
    public static let interfacesCommand = "ip -4 -o addr show"

    /// Фактический интерфейс входа клиентского трафика: `ip route get` до IP контейнера.
    /// В новых AmneziaVPN AWG-интерфейс (amn0) живёт на хосте, и трафик выходит
    /// не через docker-бридж — ядро само подскажет правильный интерфейс.
    public static func routeGetCommand(containerIP: String) -> String {
        "ip route get \(containerIP)"
    }

    /// Имя интерфейса из вывода `ip route get` / `ip route show` (токен после `dev`).
    public static func parseRouteDev(_ output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let tokens = line.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            if let devIndex = tokens.firstIndex(of: "dev"), tokens.count > devIndex + 1 {
                return tokens[devIndex + 1]
            }
        }
        return nil
    }

    /// Имена интерфейсов из `ip -4 -o addr show` (`2: amn0    inet 172.29.172.1/24 …`).
    public static func parseInterfaceNames(_ output: String) -> [String] {
        var names: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":"),
                  trimmed[..<colon].allSatisfy(\.isNumber) else { continue }
            let rest = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let name = rest.split(separator: " ").first.map(String.init)?
                .split(separator: ":").first.map(String.init) ?? ""
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Интерфейс входа клиентского трафика.
    ///
    /// Приоритет: хост-интерфейс AmneziaWG (`amn*` — новая топология, трафик клиентов
    /// приходит именно туда) → интерфейс из `ip route get` до контейнера (старая
    /// топология: docker-бридж). `awg-relay` исключается всегда — это наш relay.
    public static func ingressInterfaceName(routeDev: String?, interfaceNames: [String]) -> String? {
        let amnezia = interfaceNames.first {
            let lower = $0.lowercased()
            return lower.hasPrefix("amn") && lower != "awg-relay"
        }
        if let amnezia { return amnezia }
        if let routeDev, !routeDev.isEmpty, routeDev != "awg-relay" { return routeDev }
        return nil
    }

    // MARK: Парсеры (чистые функции для unit-тестов)

    /// Имена контейнеров из вывода `docker ps`.
    public static func parseContainerNames(_ output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Выбор контейнера AmneziaWG: предпочитаем точное `amnezia-awg`, иначе первый содержащий `awg`.
    public static func selectAmneziaContainer(from names: [String]) -> String? {
        if names.contains("amnezia-awg") { return "amnezia-awg" }
        return names.first { $0.lowercased().contains("awg") }
    }

    /// Разбор `{{json .NetworkSettings.Networks}}` и выбор рабочей сети.
    ///
    /// Контейнер может быть подключён к нескольким сетям; порядок ключей JSON не
    /// гарантирован. Дефолтная сеть `bridge` (172.17.0.0/16) выбирается в последнюю
    /// очередь: эта подсеть есть практически на любом сервере с Docker и почти всегда
    /// коллидирует с сетями сервера-выхода.
    public static func parseContainerNetworks(_ json: String) -> (networkName: String?, containerIP: String?) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            return (nil, nil)
        }
        let name: String?
        if object.count == 1 {
            name = object.first?.key
        } else {
            name = object.first(where: { $0.key != "bridge" })?.key ?? object.first?.key
        }
        guard let selected = name, let details = object[selected] as? [String: Any] else {
            return (nil, nil)
        }
        return (selected, details["IPAddress"] as? String)
    }

    /// Имя хост-интерфейса Docker-сети: кастомные сети — `br-<12 символов ID>`,
    /// дефолтная `bridge` — `docker0`.
    public static func hostInterfaceName(networkName: String, networkID: String) -> String {
        networkName == "bridge" ? "docker0" : "br-" + String(networkID.prefix(12))
    }

    /// Разбор `docker network inspect`: ID сети и подсеть из IPAM.Config.
    public static func parseNetworkInspect(_ json: String) -> (networkID: String?, subnet: String?) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let id = object["Id"] as? String
        var subnet: String?
        if let ipam = object["IPAM"] as? [String: Any],
           let configs = ipam["Config"] as? [[String: Any]],
           let first = configs.first {
            subnet = first["Subnet"] as? String
        }
        return (id, subnet)
    }

    /// Клиентская подсеть из wg0.conf контейнера: первая строка `Address = a.b.c.d/24`.
    public static func parseClientSubnet(_ wg0Conf: String) -> String? {
        for line in wg0Conf.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Address") else { continue }
            let value = trimmed.split(separator: "=", maxSplits: 1).dropFirst().first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if let network = networkAddress(value) {
                return network
            }
        }
        return nil
    }

    /// Приводит `a.b.c.d/prefix` к адресу сети (обнуляет биты хоста). Только IPv4.
    public static func networkAddress(_ cidr: String) -> String? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        let ip = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
        let network = ip & mask
        return [
            (network >> 24) & 0xFF,
            (network >> 16) & 0xFF,
            (network >> 8) & 0xFF,
            network & 0xFF,
        ].map(String.init).joined(separator: ".") + "/\(prefix)"
    }

    // MARK: Миграция с дефолтного bridge

    /// Миграция нужна, если рабочая сеть контейнера — дефолтный bridge:
    /// его подсеть (172.17.0.0/16) есть почти на каждом сервере с Docker.
    public static func requiresBridgeMigration(networkName: String?) -> Bool {
        networkName == "bridge"
    }

    /// Кандидаты подсети для выделенной сети (в порядке приоритета).
    public static let subnetCandidates = ["172.29.172.0/24", "172.28.0.0/16", "172.26.0.0/16", "10.50.0.0/16"]

    /// Первый кандидат, не занятый маршрутами ни на одном из серверов.
    public static func pickFreeSubnet(routesC1: String, routesC2: String) -> String? {
        for candidate in subnetCandidates {
            if routesC1.contains(candidate) || routesC2.contains(candidate) { continue }
            return candidate
        }
        return nil
    }

    /// Создать выделенную сеть, подключить контейнер, отключить от дефолтного bridge.
    /// Живые операции: контейнер не перезапускается, публикация портов переезжает на IP новой сети.
    public static func migrationCommand(container: String, networkName: String, subnet: String) -> String {
        """
        docker network create --subnet='\(subnet)' \(networkName) 2>/dev/null || true
        docker network connect \(networkName) \(container) 2>/dev/null || true
        docker network disconnect bridge \(container) 2>/dev/null || true
        """
    }

    // MARK: Оркестратор

    /// Полный детект окружения С1. Каждый шаг — отдельная команда, результат сохраняется в env.
    public func detect() async throws -> DetectionResult {
        // 1. Контейнер.
        let namesResult = try await runner.run(Self.listContainersCommand, timeout: 15, onOutput: nil)
        guard namesResult.succeeded else {
            throw ProvisioningError.dockerMissing(namesResult.stderr)
        }
        let names = Self.parseContainerNames(namesResult.stdout)
        guard let container = Self.selectAmneziaContainer(from: names) else {
            throw ProvisioningError.containerMissing
        }

        // 2. Сети контейнера.
        let networksResult = try await runner.run(Self.containerNetworksCommand(container: container), timeout: 15, onOutput: nil)
        guard networksResult.succeeded else {
            throw ProvisioningError.parseFailed("docker inspect (Networks): \(networksResult.stderr)")
        }
        let parsed = Self.parseContainerNetworks(networksResult.stdout)
        guard parsed.networkName != nil else {
            throw ProvisioningError.parseFailed("у контейнера \(container) нет Docker-сети")
        }

        // 3. Миграция с дефолтного bridge, если контейнер на нём.
        var migrated = false
        var selectedNetworkName = parsed.networkName!
        var selectedIP = parsed.containerIP
        if Self.requiresBridgeMigration(networkName: selectedNetworkName) {
            let routes1 = try? await runner.run(Self.routesCommand, timeout: 30, onOutput: nil)
            var routes2 = ""
            if let exitRoutesRunner {
                let result = try? await exitRoutesRunner.run(Self.routesCommand, timeout: 30, onOutput: nil)
                routes2 = result?.stdout ?? ""
            }
            guard let subnet = Self.pickFreeSubnet(routesC1: routes1?.stdout ?? "", routesC2: routes2) else {
                throw ProvisioningError.parseFailed(
                    "не удалось подобрать свободную подсеть для переноса контейнера с дефолтного bridge: все кандидаты заняты на одном из серверов"
                )
            }
            let migration = try await runner.run(
                Self.migrationCommand(container: container, networkName: Self.relayNetworkName, subnet: subnet),
                timeout: 60,
                onOutput: nil
            )
            guard migration.succeeded else {
                throw ProvisioningError.commandFailed(step: "detect-c1", exitCode: migration.exitCode, stderr: migration.stderr)
            }
            // Повторная инспекция: контейнер должен остаться только на выделенной сети.
            let reInspect = try await runner.run(Self.containerNetworksCommand(container: container), timeout: 15, onOutput: nil)
            let reParsed = Self.parseContainerNetworks(reInspect.stdout)
            guard let newName = reParsed.networkName, newName != "bridge", let newIP = reParsed.containerIP else {
                throw ProvisioningError.parseFailed("после миграции контейнер не подключён к выделенной сети \(Self.relayNetworkName)")
            }
            selectedNetworkName = newName
            selectedIP = newIP
            migrated = true
        }
        guard let containerIP = selectedIP else {
            throw ProvisioningError.parseFailed("не удалось определить IP контейнера \(container) в сети \(selectedNetworkName)")
        }

        // 4. ID/подсеть выбранной сети → интерфейс хоста.
        let networkResult = try await runner.run(Self.networkInspectCommand(network: selectedNetworkName), timeout: 15, onOutput: nil)
        guard networkResult.succeeded else {
            throw ProvisioningError.parseFailed("docker network inspect: \(networkResult.stderr)")
        }
        let network = Self.parseNetworkInspect(networkResult.stdout)
        guard let networkID = network.networkID, let subnet = network.subnet else {
            throw ProvisioningError.parseFailed("не удалось определить ID/подсеть сети \(selectedNetworkName)")
        }
        let hostInterface = Self.hostInterfaceName(networkName: selectedNetworkName, networkID: networkID)

        // 4.5. Фактический интерфейс входа клиентского трафика: в новых AmneziaVPN
        // AWG-интерфейс (amn0) живёт на хосте, и трафик выходит не через docker-бридж.
        // Собираем список интерфейсов + ответ ядра (`ip route get` до IP контейнера).
        var routeDev: String?
        if let routeGet = try? await runner.run(Self.routeGetCommand(containerIP: containerIP), timeout: 15, onOutput: nil),
           routeGet.succeeded {
            routeDev = Self.parseRouteDev(routeGet.stdout)
        }
        var interfaceNames: [String] = []
        if let addrShow = try? await runner.run(Self.interfacesCommand, timeout: 15, onOutput: nil),
           addrShow.succeeded {
            interfaceNames = Self.parseInterfaceNames(addrShow.stdout)
        }
        let ingressInterface = Self.ingressInterfaceName(routeDev: routeDev, interfaceNames: interfaceNames) ?? hostInterface

        // 5. Мягкий детект клиентской подсети и порта клиентского AWG (неуспех не останавливает
        // установку; порт обязателен для правил — проверяется в configureC1).
        let wg0Result = try? await runner.run(Self.clientSubnetCommand(container: container), timeout: 15, onOutput: nil)
        let clientSubnet = wg0Result.flatMap { Self.parseClientSubnet($0.stdout) }
        let clientPort = wg0Result.flatMap { Self.parseClientPort($0.stdout) }

        let environment = ChainState.Environment(
            bridge: ingressInterface,
            dockerSubnet: subnet,
            containerIP: containerIP,
            containerName: container,
            clientSubnet: clientSubnet,
            clientPort: clientPort,
            commit: nil
        )
        return DetectionResult(
            containerName: container,
            environment: environment,
            migratedFromDefaultBridge: migrated
        )
    }

    private func awaitRunnerClientSubnet(container: String) async throws -> SSHExecResult {
        try await runner.run(Self.clientSubnetCommand(container: container), timeout: 15, onOutput: nil)
    }
}

public extension ChainState.Environment {
    /// Содержимое файла `/etc/amnezia/chain/env` (KEY=VALUE).
    var fileContent: String {
        var lines = [
            "BRIDGE=\(bridge)",
            "DOCKER_SUBNET=\(dockerSubnet)",
            "CONTAINER_IP=\(containerIP)",
        ]
        if let containerName, !containerName.isEmpty {
            lines.append("CONTAINER_NAME=\(containerName)")
        }
        if let clientSubnet, !clientSubnet.isEmpty {
            lines.append("CLIENT_SUBNET=\(clientSubnet)")
        }
        if let clientPort, !clientPort.isEmpty {
            lines.append("CLIENT_PORT=\(clientPort)")
        }
        if let commit, !commit.isEmpty {
            lines.append("COMMIT=\(commit)")
        }
        if let commitTools, !commitTools.isEmpty {
            lines.append("COMMIT_TOOLS=\(commitTools)")
        }
        return lines.joined(separator: "\n")
    }
}
