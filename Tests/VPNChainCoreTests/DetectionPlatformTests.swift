import Foundation
import Testing
@testable import VPNChainCore

/// Фейковый транспорт: скриптованная очередь ответов с проверкой подстрок команд.
final class FakeRunner: RemoteRunner, @unchecked Sendable {
    private struct Scripted {
        let contains: String
        let result: Result<SSHExecResult, Error>
    }

    private let lock = NSLock()
    private var queue: [Scripted]
    private(set) var executed: [String] = []

    init(_ scripted: [(contains: String, result: Result<SSHExecResult, Error>)]) {
        self.queue = scripted.map { Scripted(contains: $0.contains, result: $0.result) }
    }

    func run(
        _ command: String,
        timeout: TimeInterval?,
        onOutput: (@Sendable (SSHOutputChunk) -> Void)?
    ) async throws -> SSHExecResult {
        let result = takeNext(command: command)
        switch result {
        case .success(let execResult):
            return execResult
        case .failure(let error):
            throw error
        }
    }

    /// Синхронная работа с очередью (NSLock недоступен напрямую из async-контекста).
    /// Очередь сканируется на совпадение подстроки: нет совпадений — команда проходит
    /// успешно (дефолт «всё ок» для длинных happy-path прогонов движка).
    private func takeNext(command: String) -> Result<SSHExecResult, Error> {
        lock.lock()
        defer { lock.unlock() }
        executed.append(command)
        if let index = queue.firstIndex(where: { command.contains($0.contains) }) {
            let item = queue.remove(at: index)
            if !item.contains.isEmpty, !command.contains(item.contains) {
                return .success(SSHExecResult(exitCode: 2, stdout: "", stderr: "fake: ожидалась команда с '\(item.contains)', получено: \(command)"))
            }
            return item.result
        }
        return .success(SSHExecResult(exitCode: 0, stdout: "", stderr: ""))
    }
}

func ok(_ stdout: String = "", _ stderr: String = "", code: Int = 0) -> Result<SSHExecResult, Error> {
    .success(SSHExecResult(exitCode: code, stdout: stdout, stderr: stderr))
}
/// Фиксчуны вывода docker (как на реальном сервере).
enum DockerFixtures {
    static let containerNames = "amnezia-awg\npostgres\nredis\n"

    static let containerNetworks = """
    {"amnezia_net":{"IPAMConfig":null,"Links":null,"Aliases":["a1b2"],"NetworkID":"9f7e5c1a2b3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f","EndpointID":"e1","Gateway":"172.26.0.1","IPAddress":"172.26.0.2","IPPrefixLen":16}}
    """

    static let networkInspect = """
    {"Name":"amnezia_net","Id":"9f7e5c1a2b3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f","IPAM":{"Driver":"default","Config":[{"Subnet":"172.26.0.0/16","Gateway":"172.26.0.1"}]}}
    """

    static let wg0Conf = """
    [Interface]
    Address = 10.8.1.5/24
    ListenPort = 51820
    PrivateKey = EKZ1WruHYkpXuSvEu6DMHIMwULIRLSabMH0hYQkvyWo=
    """
}

/// Тесты задачи 4.1: детект окружения С1.
struct EnvironmentDetectionTests {
    @Test func happyPathDetection() async throws {
        let runner = FakeRunner([
            ("docker ps", ok(DockerFixtures.containerNames)),
            ("NetworkSettings.Networks", ok(DockerFixtures.containerNetworks)),
            ("docker network inspect", ok(DockerFixtures.networkInspect)),
            ("wg0.conf", ok(DockerFixtures.wg0Conf)),
        ])
        let result = try await EnvironmentDetector(runner: runner).detect()

        #expect(result.containerName == "amnezia-awg")
        #expect(result.environment.bridge == "br-9f7e5c1a2b3d") // br- + 12 символов ID
        #expect(result.environment.dockerSubnet == "172.26.0.0/16")
        #expect(result.environment.containerIP == "172.26.0.2")
        #expect(result.environment.clientSubnet == "10.8.1.0/24")
    }

    @Test func containerMissingStopsDetection() async {
        let runner = FakeRunner([
            ("docker ps", ok("postgres\nredis\n")),
        ])
        do {
            _ = try await EnvironmentDetector(runner: runner).detect()
            Issue.record("Ожидался containerMissing")
        } catch let error as ProvisioningError {
            #expect(error == .containerMissing)
        } catch {
            Issue.record("Неожиданный тип: \(error)")
        }
    }

    @Test func dockerMissingStopsDetection() async {
        let runner = FakeRunner([
            ("docker ps", ok("", "/bin/sh: 1: docker: not found", code: 127)),
        ])
        do {
            _ = try await EnvironmentDetector(runner: runner).detect()
            Issue.record("Ожидался dockerMissing")
        } catch let error as ProvisioningError {
            guard case .dockerMissing = error else {
                Issue.record("Ожидался dockerMissing, получено: \(error)")
                return
            }
        } catch {
            Issue.record("Неожиданный тип: \(error)")
        }
    }

    @Test func envFileContentIncludesOptionalKeys() {
        let env = ChainState.Environment(
            bridge: "br-abc",
            dockerSubnet: "172.26.0.0/16",
            containerIP: "172.26.0.2",
            clientSubnet: "10.8.1.0/24",
            clientPort: "44949",
            commit: "abc123"
        )
        let content = env.fileContent
        #expect(content.contains("BRIDGE=br-abc"))
        #expect(content.contains("DOCKER_SUBNET=172.26.0.0/16"))
        #expect(content.contains("CONTAINER_IP=172.26.0.2"))
        #expect(content.contains("CLIENT_SUBNET=10.8.1.0/24"))
        #expect(content.contains("CLIENT_PORT=44949"))
        #expect(content.contains("COMMIT=abc123"))

        // Round-trip: CLIENT_PORT разбирается из env, старый env без него — валиден.
        let parsed = try! ChainStateParser.parseEnvironment(content)
        #expect(parsed.clientPort == "44949")
        let legacy = try! ChainStateParser.parseEnvironment("BRIDGE=b\nDOCKER_SUBNET=s\nCONTAINER_IP=i")
        #expect(legacy.clientPort == nil)

        let minimal = ChainState.Environment(bridge: "b", dockerSubnet: "s", containerIP: "i").fileContent
        #expect(!minimal.contains("CLIENT_SUBNET"))
        #expect(!minimal.contains("CLIENT_PORT"))
        #expect(!minimal.contains("COMMIT"))
    }

    /// Регрессия приёмки: конфиг клиентского AWG в новых AmneziaVPN — `awg0.conf`,
    /// а не `wg0.conf` (из-за этого не определялись подсеть и порт клиентов).
    @Test func detectsClientPortAndConfPaths() {
        let conf = """
        ==FILE /opt/amnezia/awg/awg0.conf==
        [Interface]
        Address = 10.8.1.0/24
        ListenPort = 44949
        PrivateKey = SECRET
        """
        #expect(EnvironmentDetector.parseClientSubnet(conf) == "10.8.1.0/24")
        #expect(EnvironmentDetector.parseClientPort(conf) == "44949")
        #expect(EnvironmentDetector.parseClientPort("[Interface]\nAddress = 10.8.1.0/24\n") == nil)
        #expect(EnvironmentDetector.parseClientPort("ListenPort = 70000") == nil)

        let command = EnvironmentDetector.clientSubnetCommand(container: "amnezia-awg2")
        #expect(command.contains("/opt/amnezia/awg/awg0.conf"))
        #expect(command.contains("/opt/amnezia/awg/wg0.conf"))
    }

    // MARK: Чистые парсеры

    @Test func containerSelectionPrefersAmneziaAwg() {
        #expect(EnvironmentDetector.selectAmneziaContainer(from: ["postgres", "amnezia-awg", "awg-helper"]) == "amnezia-awg")
        #expect(EnvironmentDetector.selectAmneziaContainer(from: ["postgres", "awg-helper"]) == "awg-helper")
        #expect(EnvironmentDetector.selectAmneziaContainer(from: ["postgres"]) == nil)
    }

    @Test func parsesContainerNetworksJSON() {
        let parsed = EnvironmentDetector.parseContainerNetworks(DockerFixtures.containerNetworks)
        #expect(parsed.networkName == "amnezia_net")
        #expect(parsed.containerIP == "172.26.0.2")
        #expect(EnvironmentDetector.parseContainerNetworks("{}").networkName == nil)
        #expect(EnvironmentDetector.parseContainerNetworks("not json").containerIP == nil)
    }

    @Test func parsesNetworkInspectJSON() {
        let parsed = EnvironmentDetector.parseNetworkInspect(DockerFixtures.networkInspect)
        #expect(parsed.networkID?.hasPrefix("9f7e5c1a2b3d") == true)
        #expect(parsed.subnet == "172.26.0.0/16")
    }

    @Test func parsesMultiNetworkContainerPrefersCustom() {
        let json = #"{"bridge":{"IPAddress":"172.17.0.2"},"amnezia-dns-net":{"IPAddress":"172.29.172.2"}}"#
        let parsed = EnvironmentDetector.parseContainerNetworks(json)
        #expect(parsed.networkName == "amnezia-dns-net")
        #expect(parsed.containerIP == "172.29.172.2")
    }

    @Test func hostInterfaceNameForBridgeAndCustom() {
        #expect(EnvironmentDetector.hostInterfaceName(networkName: "bridge", networkID: "c8cb5493f698") == "docker0")
        #expect(
            EnvironmentDetector.hostInterfaceName(networkName: "amnezia_net", networkID: "9f7e5c1a2b3d4e5f")
                == "br-9f7e5c1a2b3d"
        )
    }

    @Test func routeGetCommandAndDevParsing() {
        #expect(EnvironmentDetector.routeGetCommand(containerIP: "172.29.172.2") == "ip route get 172.29.172.2")
        // Новая топология AmneziaVPN: AWG-интерфейс amn0 живёт на хосте.
        #expect(
            EnvironmentDetector.parseRouteDev("172.29.172.2 dev amn0 src 172.29.172.1 uid 0\n    cache")
                == "amn0"
        )
        // Старая топология: трафик до контейнера идёт через docker-бридж.
        #expect(
            EnvironmentDetector.parseRouteDev("172.29.172.2 dev br-9f7e5c1a2b3d src 172.29.172.1")
                == "br-9f7e5c1a2b3d"
        )
        // Мусорный вывод — nil (движок останется на вычисленном имени бриджа).
        #expect(EnvironmentDetector.parseRouteDev("RTNETLINK answers: Network is unreachable") == nil)
    }

    @Test func ingressInterfacePrefersAmnInterface() {
        let interfaces = EnvironmentDetector.parseInterfaceNames("""
        1: lo    inet 127.0.0.1/8 scope host lo
        2: eth0    inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0
        12: amn0    inet 172.29.172.1/24 brd 172.29.172.255 scope global amn0
        15: br-9f7e5c1a2b3d: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
        """)
        #expect(interfaces == ["lo", "eth0", "amn0", "br-9f7e5c1a2b3d"])
        // Новая топология: amn0 приоритетнее ответа маршрута (тот мог указать на br-…).
        #expect(EnvironmentDetector.ingressInterfaceName(routeDev: "br-9f7e5c1a2b3d", interfaceNames: interfaces) == "amn0")
        // Старая топология: amn0 нет → интерфейс из ip route get.
        #expect(EnvironmentDetector.ingressInterfaceName(routeDev: "br-9f7e5c1a2b3d", interfaceNames: ["lo", "eth0"]) == "br-9f7e5c1a2b3d")
        // Ничего не определилось → nil (движок возьмёт имя бриджа из ID сети).
        #expect(EnvironmentDetector.ingressInterfaceName(routeDev: nil, interfaceNames: []) == nil)
        // Наш relay-интерфейс не может быть интерфейсом входа.
        #expect(EnvironmentDetector.ingressInterfaceName(routeDev: "awg-relay", interfaceNames: []) == nil)
    }

    @Test func bridgeMigrationRequiresAndCommands() {
        #expect(EnvironmentDetector.requiresBridgeMigration(networkName: "bridge"))
        #expect(!EnvironmentDetector.requiresBridgeMigration(networkName: "amnezia_net"))
        #expect(!EnvironmentDetector.requiresBridgeMigration(networkName: nil))

        let command = EnvironmentDetector.migrationCommand(container: "amnezia-awg2", networkName: "amnezia-relay-net", subnet: "172.29.172.0/24")
        #expect(command.contains("docker network create --subnet='172.29.172.0/24' amnezia-relay-net"))
        #expect(command.contains("docker network connect amnezia-relay-net amnezia-awg2"))
        #expect(command.contains("docker network disconnect bridge amnezia-awg2"))
    }

    @Test func pickFreeSubnetSkipsUsedOnBothServers() {
        // 172.29.172.0/24 занята на С1 → следующий кандидат.
        let c1Used = "default via 1.2.3.4 dev eth0\n172.29.172.0/24 dev amn0 proto kernel"
        #expect(EnvironmentDetector.pickFreeSubnet(routesC1: c1Used, routesC2: "") == "172.28.0.0/16")
        // 172.28.0.0/16 занята на С2 → пропускаем тоже.
        #expect(EnvironmentDetector.pickFreeSubnet(routesC1: c1Used, routesC2: "172.28.0.0/16 dev br-x") == "172.26.0.0/16")
        // Всё свободно — первый кандидат.
        #expect(EnvironmentDetector.pickFreeSubnet(routesC1: "", routesC2: "") == "172.29.172.0/24")
        // Все кандидаты заняты.
        let everything = ["172.29.172.0/24", "172.28.0.0/16", "172.26.0.0/16", "10.50.0.0/16"].joined(separator: "\n")
        #expect(EnvironmentDetector.pickFreeSubnet(routesC1: everything, routesC2: everything) == nil)
    }

    @Test func clientSubnetParsedAndMasked() {
        #expect(EnvironmentDetector.parseClientSubnet(DockerFixtures.wg0Conf) == "10.8.1.0/24")
        #expect(EnvironmentDetector.parseClientSubnet("Address = 172.16.3.77/16") == "172.16.0.0/16")
        #expect(EnvironmentDetector.parseClientSubnet("Address = 10.0.0.1/32") == "10.0.0.1/32")
        #expect(EnvironmentDetector.parseClientSubnet("ListenPort = 51820") == nil)
    }

    @Test func networkAddressMasksHostBits() {
        #expect(EnvironmentDetector.networkAddress("10.8.1.5/24") == "10.8.1.0/24")
        #expect(EnvironmentDetector.networkAddress("10.8.1.5/25") == "10.8.1.0/25")
        #expect(EnvironmentDetector.networkAddress("10.8.1.5/33") == nil)
        #expect(EnvironmentDetector.networkAddress("999.1.1.1/24") == nil)
    }
}

/// Тесты задачи 4.2: проверка ОС/архитектуры.
struct PlatformCheckTests {
    @Test func parsesUbuntu2204X86() throws {
        let osRelease = """
        NAME="Ubuntu"
        VERSION_ID="22.04"
        """
        let platform = try PlatformParser.parsePlatform(osRelease: osRelease, uname: "x86_64")
        #expect(platform == ServerPlatform(os: .ubuntu, majorVersion: 22, arch: .x86_64))
        try PlatformParser.ensureSupported(platform)
        #expect(platform.displayName == "Ubuntu 22, x86_64")
    }

    @Test func parsesDebian12Aarch64() throws {
        let platform = try PlatformParser.parsePlatform(osRelease: "NAME=\"Debian GNU/Linux\"\nVERSION_ID=\"12\"", uname: "aarch64")
        try PlatformParser.ensureSupported(platform)
        #expect(platform.os == .debian)
    }

    @Test func unknownOSRejected() {
        #expect(throws: PlatformParser.PlatformError.unknownOS("CentOS Linux")) {
            try PlatformParser.parsePlatform(osRelease: "NAME=\"CentOS Linux\"\nVERSION_ID=\"7\"", uname: "x86_64")
        }
    }

    @Test func unsupportedVersionRejected() {
        let platform = try? PlatformParser.parsePlatform(osRelease: "NAME=\"Ubuntu\"\nVERSION_ID=\"23.10\"", uname: "x86_64")
        #expect(platform != nil)
        #expect(throws: ProvisioningError.unsupportedPlatform("Ubuntu 23, x86_64")) {
            try PlatformParser.ensureSupported(platform!)
        }
    }

    @Test func unknownArchRejected() {
        #expect(throws: PlatformParser.PlatformError.unknownArch("armv7l")) {
            try PlatformParser.parsePlatform(osRelease: "NAME=\"Debian GNU/Linux\"\nVERSION_ID=\"12\"", uname: "armv7l")
        }
    }

    @Test func probeOutputParsed() throws {
        let output = """
        NAME="Ubuntu"
        VERSION_ID="24.04"
        ---VPNCHAIN---
        x86_64
        """
        let platform = try PlatformParser.parseProbeOutput(output)
        #expect(platform.majorVersion == 24)
        try PlatformParser.ensureSupported(platform)
    }
}
