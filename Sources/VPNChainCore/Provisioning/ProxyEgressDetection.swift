import Foundation

/// Найденные Docker-сети сервера-входа и сети, принадлежащие AmneziaVPN.
/// Сеть AmneziaVPN в режим проксирования не попадает никогда (см. спеку proxy-egress).
public struct ProxyNetworkDetection: Sendable, Equatable {
    public let networks: [ProxyNetwork]
    public let amneziaNetworks: Set<String>

    public init(networks: [ProxyNetwork], amneziaNetworks: Set<String>) {
        self.networks = networks
        self.amneziaNetworks = amneziaNetworks
    }
}

/// Детект Docker-сетей и публичного IP сервера-выхода для режима проксирования.
/// Все значения определяются на серверах, без хардкода имён и подсетей.
public struct ProxyNetworkDetector: Sendable {
    private let runner: any RemoteRunner

    public init(runner: any RemoteRunner) {
        self.runner = runner
    }

    // MARK: Команды

    public static let listNetworksCommand = "docker network ls --format '{{.Name}}'"

    public static func networkInspectCommand(network: String) -> String {
        "docker network inspect -f '{{json .}}' \(network)"
    }

    public static func containerNetworkNamesCommand(container: String) -> String {
        "docker inspect -f '{{json .NetworkSettings.Networks}}' \(container)"
    }

    /// Публичный IP: первый доступный сервис; IPv4 обязателен (туннель IPv4-only).
    public static let publicIPCommand =
        "curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 10 https://ifconfig.me/ip 2>/dev/null"

    public static let hostEgressCommand = publicIPCommand

    /// Фактический IP из контейнера: curl, при его отсутствии — wget.
    public static func containerEgressCommand(container: String) -> String {
        "docker exec \(container) sh -c 'curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || wget -qO- -T 10 https://api.ipify.org 2>/dev/null'"
    }

    // MARK: Парсеры (чистые функции для unit-тестов)

    /// Имена сетей из `docker network ls --format '{{.Name}}'`.
    public static func parseNetworkNames(_ output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Имена сетей, к которым подключён контейнер (`{{json .NetworkSettings.Networks}}`).
    public static func parseContainerNetworkNames(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        return Array(object.keys)
    }

    /// Подсеть и bridge сети из `docker network inspect` (nil — сеть без IPv4-подсети).
    public static func parseProxyNetwork(name: String, json: String) -> ProxyNetwork? {
        let inspected = EnvironmentDetector.parseNetworkInspect(json)
        guard let id = inspected.networkID, let subnet = inspected.subnet, !subnet.isEmpty else {
            return nil
        }
        return ProxyNetwork(
            name: name,
            subnet: subnet,
            bridge: EnvironmentDetector.hostInterfaceName(networkName: name, networkID: id)
        )
    }

    /// Публичный IPv4 из вывода curl; мусор/HTML/пустой ответ → nil.
    public static func parsePublicIP(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
            octets.allSatisfy({ part in
                guard let number = Int(part), (0...255).contains(number) else { return false }
                return String(number) == part || number == 0
            })
        else {
            return nil
        }
        return value
    }

    /// Сети, которые не участвуют в режиме: служебные host/none и сеть AmneziaVPN.
    public static func isServiceNetwork(_ name: String) -> Bool {
        name == "host" || name == "none"
    }

    // MARK: Оркестрация

    /// Все Docker-сети сервера-входа с подсетями и bridge-интерфейсами.
    /// `amneziaContainer` — имя контейнера AmneziaWG: его сети исключаются всегда.
    public func detect(amneziaContainer: String?) async throws -> ProxyNetworkDetection {
        let namesResult = try await runner.run(
            Self.listNetworksCommand, timeout: 30, onOutput: nil)
        guard namesResult.succeeded else {
            throw ProvisioningError.dockerMissing(namesResult.stderr)
        }
        var amneziaNetworks: Set<String> = []
        if let amneziaContainer, !amneziaContainer.isEmpty,
            let containerResult = try? await runner.run(
                Self.containerNetworkNamesCommand(container: amneziaContainer), timeout: 15,
                onOutput: nil), containerResult.succeeded
        {
            amneziaNetworks = Set(Self.parseContainerNetworkNames(containerResult.stdout))
        }

        var networks: [ProxyNetwork] = []
        for name in Self.parseNetworkNames(namesResult.stdout) {
            guard !Self.isServiceNetwork(name) else { continue }
            guard
                let inspect = try? await runner.run(
                    Self.networkInspectCommand(network: name), timeout: 15, onOutput: nil),
                inspect.succeeded
            else {
                continue
            }
            if let network = Self.parseProxyNetwork(name: name, json: inspect.stdout) {
                networks.append(network)
            }
        }
        return ProxyNetworkDetection(
            networks: networks.sorted { $0.name < $1.name },
            amneziaNetworks: amneziaNetworks
        )
    }

    /// Публичный IP сервера-выхода (для сравнения фактического выхода).
    public func publicIP() async throws -> String {
        let result = try await runner.run(Self.publicIPCommand, timeout: 30, onOutput: nil)
        guard let ip = Self.parsePublicIP(result.stdout) else {
            throw ProvisioningError.parseFailed(
                "не удалось определить публичный IP сервера-выхода (нет ответа от сервиса проверки IP)"
            )
        }
        return ip
    }
}
