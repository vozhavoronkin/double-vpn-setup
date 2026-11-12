import Foundation
import Testing

@testable import VPNChainCore

/// Тесты режима проксирования исходящего трафика (задача proxy-egress):
/// модель состояния, настройка в профиле, детект сетей и рендер правил.
struct ProxyEgressTests {
    private let networkInspectFixture: (String, String) -> String = { id, subnet in
        """
        {"Name":"net","Id":"\(id)","IPAM":{"Driver":"default","Config":[{"Subnet":"\(subnet)","Gateway":"10.0.0.1"}]}}
        """
    }

    // MARK: 1.1 — состояние и настройка

    @Test func proxiesStateRoundTripsWithMarker() throws {
        let network = ProxyNetwork(
            name: "3x-ui", subnet: "172.18.0.0/16", bridge: "br-0123456789ab")
        let state = ProxiesState(enabled: true, exitIP: "203.0.113.9", networks: [network])
        let json = state.json()

        #expect(json.contains("\"managed-by\" : \"amnezia-chain\""))
        #expect(json.contains("\"enabled\" : true"))
        #expect(json.contains("172.18.0.0/16"))

        let decoded = try #require(ProxiesState.decode(json))
        #expect(decoded == state)
        #expect(decoded.networks == [network])
    }

    @Test func proxiesStateWithoutFileOrWithForeignMarkerMeansDisabled() {
        #expect(ProxiesState.decode("") == nil)
        #expect(ProxiesState.decode("не json") == nil)
        #expect(ProxiesState.decode("{\"managed-by\":\"other\",\"enabled\":true}") == nil)
    }

    @Test func proxySettingsAreDisabledByDefault() {
        let settings = ProxyEgressSettings()
        #expect(!settings.enabled)
        #expect(settings.excludedNetworks.isEmpty)
        #expect(!settings.isExcluded("3x-ui"))
    }

    @Test func profileStorePersistsProxySettings() throws {
        let suiteName = "vpnchain-proxy-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = ProfileStore(
            defaults: defaults, keychain: KeychainStore(service: "ru.vpnchain.proxy.tests"))

        #expect(store.proxyEgressSettings == ProxyEgressSettings())

        store.proxyEgressSettings = ProxyEgressSettings(
            enabled: true, excludedNetworks: ["3x-ui"])
        #expect(store.proxyEgressSettings.enabled)
        #expect(store.proxyEgressSettings.isExcluded("3x-ui"))
    }

    // MARK: 1.2 — детект сетей и публичного IP

    @Test func parsesNetworkNamesAndContainerNetworks() {
        #expect(
            ProxyNetworkDetector.parseNetworkNames("bridge\n3x-ui\n\namnezia_net\n")
                == ["bridge", "3x-ui", "amnezia_net"])
        #expect(
            Set(
                ProxyNetworkDetector.parseContainerNetworkNames(
                    DockerFixtures.containerNetworks)) == ["amnezia_net"])
        #expect(ProxyNetworkDetector.parseContainerNetworkNames("") == [])
    }

    @Test func parsesProxyNetworkWithBridgeName() throws {
        let json = networkInspectFixture(
            "9f7e5c1a2b3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f", "172.26.0.0/16")
        let network = try #require(
            ProxyNetworkDetector.parseProxyNetwork(name: "amnezia_net", json: json))
        #expect(network.name == "amnezia_net")
        #expect(network.subnet == "172.26.0.0/16")
        #expect(network.bridge == "br-9f7e5c1a2b3d")

        let defaultBridge = try #require(
            ProxyNetworkDetector.parseProxyNetwork(
                name: "bridge",
                json: networkInspectFixture("abcdef1234567890", "172.17.0.0/16")))
        #expect(defaultBridge.bridge == "docker0")
    }

    @Test func rejectsNetworkWithoutSubnet() {
        #expect(
            ProxyNetworkDetector.parseProxyNetwork(
                name: "host", json: "{\"Name\":\"host\",\"Id\":\"abc\",\"IPAM\":{\"Config\":[]}}")
                == nil)
    }

    @Test func parsesPublicIPv4Only() {
        #expect(ProxyNetworkDetector.parsePublicIP("203.0.113.9\n") == "203.0.113.9")
        #expect(ProxyNetworkDetector.parsePublicIP("") == nil)
        #expect(ProxyNetworkDetector.parsePublicIP("<html>error</html>") == nil)
        #expect(ProxyNetworkDetector.parsePublicIP("203.0.113.999") == nil)
    }

    @Test func serviceNetworksAreExcluded() {
        #expect(ProxyNetworkDetector.isServiceNetwork("host"))
        #expect(ProxyNetworkDetector.isServiceNetwork("none"))
        #expect(!ProxyNetworkDetector.isServiceNetwork("3x-ui"))
    }

    @Test func detectsNetworksAndAmneziaNetwork() async throws {
        let id = "9f7e5c1a2b3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f"
        let runner = FakeRunner([
            ("docker network ls", ok("bridge\n3x-ui\namnezia_net\nhost\n")),
            ("3x-ui", ok(networkInspectFixture("aaaabbbbccccdddd", "172.18.0.0/16"))),
            ("amnezia_net", ok(networkInspectFixture(id, "172.26.0.0/16"))),
            ("bridge", ok(networkInspectFixture("eeeeffff00001111", "172.17.0.0/16"))),
            ("NetworkSettings.Networks", ok(DockerFixtures.containerNetworks)),
        ])
        let detector = ProxyNetworkDetector(runner: runner)
        let detection = try await detector.detect(amneziaContainer: "amnezia-awg")

        #expect(detection.amneziaNetworks == ["amnezia_net"])
        #expect(detection.networks.map(\.name) == ["3x-ui", "amnezia_net", "bridge"])

        let selected = ProxyEgressRules.selectedNetworks(
            all: detection.networks,
            settings: ProxyEgressSettings(enabled: true),
            amneziaNetworks: detection.amneziaNetworks
        )
        // Сеть AmneziaVPN не попадает в режим никогда, даже без явного исключения.
        #expect(selected.map(\.name) == ["3x-ui", "bridge"])
    }

    /// Регрессия с реальной пары: контейнер AmneziaVPN подключён к своей сети И к
    /// дефолтной `bridge`, а прокси живут в `bridge`. Исключаться должен только bridge
    /// клиентской сети, иначе прокси в `bridge` не попадают в список.
    @Test func defaultBridgeStaysAvailableWhenAmneziaContainerUsesTwoNetworks() async throws {
        let id = "9f7e5c1a2b3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f"
        let runner = FakeRunner([
            ("docker network ls", ok("bridge\namnezia_net\n3x-ui\n")),
            ("3x-ui", ok(networkInspectFixture("aaaabbbbccccdddd", "172.18.0.0/16"))),
            ("amnezia_net", ok(networkInspectFixture(id, "172.26.0.0/16"))),
            ("bridge", ok(networkInspectFixture("eeeeffff00001111", "172.17.0.0/16"))),
        ])
        let detector = ProxyNetworkDetector(runner: runner)
        let detection = try await detector.detect(
            amneziaContainer: "amnezia-awg2",
            amneziaBridge: "br-" + String(id.prefix(12))
        )

        #expect(detection.amneziaNetworks == ["amnezia_net"])
        #expect(detection.networks.map(\.name) == ["3x-ui", "amnezia_net", "bridge"])

        let selected = ProxyEgressRules.selectedNetworks(
            all: detection.networks,
            settings: ProxyEgressSettings(enabled: true),
            amneziaNetworks: detection.amneziaNetworks
        )
        #expect(selected.map(\.name) == ["3x-ui", "bridge"])
    }

    /// Реальный сервер: `BRIDGE=amn0` — интерфейс контейнера, а не docker-bridge,
    /// поэтому совпадения по bridge нет. Прокси в `bridge` всё равно должны быть
    /// доступны: исключаются только кастомные сети контейнера AmneziaVPN.
    @Test func nonDockerBridgeInEnvKeepsDefaultNetworkAvailable() async throws {
        let containerNetworks = """
            {"amnezia_net":{"IPAddress":"172.26.0.2"},"bridge":{"IPAddress":"172.17.0.2"}}
            """
        let runner = FakeRunner([
            ("docker network ls", ok("bridge\namnezia_net\n")),
            ("amnezia_net", ok(networkInspectFixture("c34b8a7fffaf0000", "172.26.0.0/16"))),
            ("bridge", ok(networkInspectFixture("eeeeffff00001111", "172.17.0.0/16"))),
            ("NetworkSettings.Networks", ok(containerNetworks)),
        ])
        let detection = try await ProxyNetworkDetector(runner: runner).detect(
            amneziaContainer: "amnezia-awg2",
            amneziaBridge: "amn0"
        )

        #expect(detection.amneziaNetworks == ["amnezia_net"])
        let selected = ProxyEgressRules.selectedNetworks(
            all: detection.networks,
            settings: ProxyEgressSettings(enabled: true),
            amneziaNetworks: detection.amneziaNetworks
        )
        #expect(selected.map(\.name) == ["bridge"])
    }

    @Test func exclusionRemovesNetworkFromSelection() {
        let networks = [
            ProxyNetwork(name: "3x-ui", subnet: "172.18.0.0/16", bridge: "br-aaaabbbbcccc"),
            ProxyNetwork(name: "apps", subnet: "172.19.0.0/16", bridge: "br-ddddeeeeffff"),
        ]
        let selected = ProxyEgressRules.selectedNetworks(
            all: networks,
            settings: ProxyEgressSettings(enabled: true, excludedNetworks: ["3x-ui"]),
            amneziaNetworks: []
        )
        #expect(selected.map(\.name) == ["apps"])
    }

    @Test func exitPublicIPDetection() async throws {
        let runner = FakeRunner([("api.ipify.org", ok("203.0.113.9\n"))])
        #expect(try await ProxyNetworkDetector(runner: runner).publicIP() == "203.0.113.9")

        let broken = FakeRunner([("api.ipify.org", ok(""))])
        await #expect(throws: ProvisioningError.self) {
            _ = try await ProxyNetworkDetector(runner: broken).publicIP()
        }
    }

    // MARK: 2.1–2.3 — правила сервера-входа и IPv6

    private let networks = [
        ProxyNetwork(name: "3x-ui", subnet: "172.18.0.0/16", bridge: "br-aaaabbbbcccc"),
        ProxyNetwork(name: "apps", subnet: "172.19.0.0/16", bridge: "br-ddddeeeeffff"),
    ]

    @Test func entryScriptMarksHostAndContainersWithRepliesExcluded() {
        let script = ProxyEgressRules.renderEntryScript(
            enabled: true, networks: networks, exitIP: "203.0.113.9", clientPort: "51820")

        #expect(script.contains("# managed-by: amnezia-chain"))
        // Область режима — только контейнеры: хостовые цепочки не создаются.
        #expect(!script.contains("-A VPNCHAIN_HOST_OUT"))
        #expect(!script.contains("-I OUTPUT 1 -j VPNCHAIN_HOST_OUT"))
        #expect(!script.contains("ip6tables -A VPNCHAIN_PROXY6_HOST"))
        // Ответы клиентам прокси не маркируются.
        #expect(script.contains("VPNCHAIN_DOCKER_OUT -m conntrack --ctdir REPLY -j RETURN"))
        // IP выхода (петля WireGuard) и приватные сети исключены.
        #expect(script.contains("-d \"$EXIT_IP\" -j RETURN"))
        #expect(script.contains("'10.0.0.0/8'"))
        #expect(script.contains("'192.168.0.0/16'"))
        #expect(script.contains("'169.254.0.0/16'"))
        #expect(script.contains("'224.0.0.0/4'"))
        // Маркировка меткой relay-туннеля и подхват каждой включённой сети.
        #expect(script.contains("--set-mark \"$MARK\""))
        #expect(script.contains("VPNCHAIN_DOCKER_OUT -i 'br-aaaabbbbcccc' -j MARK"))
        #expect(script.contains("VPNCHAIN_DOCKER_OUT -i 'br-ddddeeeeffff' -j MARK"))
        // Ответы клиентского AWG не маркируются.
        #expect(script.contains("--sport \"$CLIENT_PORT\" -j RETURN"))
        // Идемпотентность вставки jump'ов.
        #expect(
            script.contains(
                "iptables -t mangle -C PREROUTING -j VPNCHAIN_DOCKER_OUT 2>/dev/null ||"))
        // SNAT в туннель: контейнерный трафик входит в awg-relay с адресом туннеля —
        // иначе cryptokey routing (AllowedIPs) дропает его на сервере-выходе.
        #expect(
            script.contains(
                "iptables -t nat -C POSTROUTING -s \"$s\" -o awg-relay -j MASQUERADE 2>/dev/null ||"
            ))
        #expect(
            script.contains(
                "iptables -t nat -I POSTROUTING 1 -s \"$s\" -o awg-relay -j MASQUERADE"))
        #expect(script.contains("'172.18.0.0/16' '172.19.0.0/16'"))
        // Прежние SNAT-подсети снимаются по списку из состояния.
        #expect(
            script.contains(
                "while iptables -t nat -D POSTROUTING -s \"$s\" -o awg-relay -j MASQUERADE"))
        // Состояние пишется с правами 0600.
        #expect(script.contains("chmod 0600 '/etc/amnezia/chain/proxies.json'"))
    }

    @Test func entryScriptWithoutClientPortOmitsSourceExclusions() {
        let script = ProxyEgressRules.renderEntryScript(
            enabled: true, networks: networks, exitIP: "203.0.113.9", clientPort: nil)
        #expect(script.contains("CLIENT_PORT=''"))
        #expect(!script.contains("--sport \"$CLIENT_PORT\""))
    }

    @Test func disabledEntryScriptOnlyRemovesItsRules() {
        let script = ProxyEgressRules.renderEntryScript(
            enabled: false, networks: [], exitIP: "", clientPort: "51820")
        // Снятие ровно своих цепочек, без создания маркировки.
        #expect(!script.contains("-A VPNCHAIN_HOST_OUT -j MARK"))
        #expect(!script.contains("-N VPNCHAIN_HOST_OUT"))
        #expect(!script.contains("ip6tables -A VPNCHAIN_PROXY6_HOST -j DROP"))
        #expect(script.contains("-D OUTPUT -j VPNCHAIN_HOST_OUT"))
        #expect(script.contains("-X VPNCHAIN_DOCKER_OUT"))
        // Правила Amnezia не трогаются.
        #expect(!script.contains("VPNCHAIN_MARK"))
        #expect(!script.contains("DOCKER-USER"))
        // Состояние фиксирует выключенный режим.
        #expect(script.contains("\"enabled\" : false"))
    }

    @Test func enabledEntryScriptBlocksIPv6ExceptLocal() {
        let script = ProxyEgressRules.renderEntryScript(
            enabled: true, networks: networks, exitIP: "203.0.113.9", clientPort: nil)
        // Хостовой IPv6 не блокируется: хост вне области режима.
        #expect(!script.contains("ip6tables -A VPNCHAIN_PROXY6_HOST"))
        #expect(!script.contains("ip6tables -I OUTPUT"))
        // IPv6-docker-цепочка — в таблице mangle: PREROUTING существует только
        // там (в filter-таблице её нет, и вставка падает с
        // «No chain/target/match by that name»). Регрессия с реального сервера.
        #expect(
            script.contains(
                "ip6tables -t mangle -A VPNCHAIN_PROXY6_DOCKER -m conntrack --ctdir REPLY -j RETURN"
            ))
        #expect(
            script.contains(
                "ip6tables -t mangle -A VPNCHAIN_PROXY6_DOCKER -i 'br-aaaabbbbcccc' -j DROP"))
        #expect(
            script.contains("ip6tables -t mangle -I PREROUTING 1 -j VPNCHAIN_PROXY6_DOCKER"))
        #expect(!script.contains("ip6tables -A VPNCHAIN_PROXY6_DOCKER"))
        #expect(!script.contains("ip6tables -I PREROUTING"))
        #expect(!script.contains("ip6tables -D PREROUTING"))
    }

    @Test func validationRejectsValuesThatReachShell() throws {
        // Валидные значения проходят.
        try ProxyEgressRules.validate(
            networks: networks, exitIP: "203.0.113.9", wanInterface: "eth0")

        // Подсеть, bridge, IP и интерфейс — только безопасные форматы.
        #expect(!ProxyEgressRules.isValidSubnet("172.18.0.0/33"))
        #expect(!ProxyEgressRules.isValidSubnet("172.18.0.0/16; rm -rf /"))
        #expect(!ProxyEgressRules.isValidIPv4("203.0.113"))
        #expect(!ProxyEgressRules.isValidInterface("br-aa; reboot"))
        #expect(!ProxyEgressRules.isValidInterface("very-long-interface-name"))

        let badNetwork = [
            ProxyNetwork(name: "evil", subnet: "172.18.0.0/16; reboot", bridge: "br-aaaaaaaaaaaa")
        ]
        #expect(throws: ProvisioningError.self) {
            try ProxyEgressRules.validate(
                networks: badNetwork, exitIP: "203.0.113.9", wanInterface: "eth0")
        }
        #expect(throws: ProvisioningError.self) {
            try ProxyEgressRules.validate(
                networks: networks, exitIP: "not-an-ip", wanInterface: "eth0")
        }
    }

    @Test func dockerCommandsAreShellQuotedAndNamesValidated() {
        #expect(ProxyNetworkDetector.shellQuote("3x-ui") == "'3x-ui'")
        #expect(ProxyNetworkDetector.shellQuote("a'b") == "'a'\\''b'")
        #expect(ProxyNetworkDetector.isValidObjectName("amnezia-awg2"))
        #expect(ProxyNetworkDetector.isValidObjectName("my_net.1:2"))
        #expect(!ProxyNetworkDetector.isValidObjectName("name; reboot"))
        #expect(!ProxyNetworkDetector.isValidObjectName("with space"))
    }

    @Test func entryActionsUseManagedScriptAndUnit() throws {
        let actions = ProxyEgressRules.entryActions(
            enabled: true, networks: networks, exitIP: "203.0.113.9", clientPort: "51820")
        #expect(actions.map(\.id) == ["proxy-entry"])
        let command = actions[0].apply
        #expect(command.contains("vpn-chain-proxy-rules.sh"))
        #expect(command.contains("vpn-chain-proxy.service"))
        #expect(command.contains("systemctl restart vpn-chain-proxy.service"))
        #expect(command.contains("systemctl enable vpn-chain-proxy.service"))
    }

    // MARK: 3.1–3.2 — сервер-выход (только очистка прежней схемы)

    /// Регрессия с реальной пары: маршруты и NAT на выходе ломали его собственный
    /// Docker (совпадение дефолтных подсетей) и не помогали — туннель дропает чужие
    /// источники по AllowedIPs. Теперь SNAT на входе, на выходе ничего не добавляется.
    @Test func exitScriptAddsNothingAndCleansLegacyOnly() {
        let script = ProxyEgressRules.renderExitScript(
            enabled: true, networks: networks, wanInterface: "eth0", exitIP: "203.0.113.9")

        #expect(script.contains("WAN='eth0'"))
        // Ничего не добавляется: ни маршрутов, ни MASQUERADE.
        #expect(!script.contains("ip route replace"))
        #expect(!script.contains("-A POSTROUTING"))
        #expect(!script.contains("-I POSTROUTING"))
        // Следы прежней схемы снимаются по списку из состояния.
        #expect(script.contains("OLD_SUBNETS=$(sed -n"))
        #expect(script.contains("ip route del \"$s\" dev awg-relay 2>/dev/null || true"))
        #expect(script.contains("while iptables -t nat -D POSTROUTING -s \"$s\""))
        // Состояние с правами 0600 и маркером.
        #expect(script.contains("chmod 0600 \"$STATE\""))
        #expect(script.contains("\"managed-by\" : \"amnezia-chain\""))
        #expect(script.contains("\"enabled\" : true"))
    }

    @Test func exitScriptWithoutNetworksRemovesEverything() {
        let script = ProxyEgressRules.renderExitScript(
            enabled: false, networks: [], wanInterface: "ens3", exitIP: "")
        #expect(script.contains("ip route del \"$s\" dev awg-relay"))
        #expect(script.contains("\"enabled\" : false"))
    }

    @Test func exitActionsUseManagedScriptAndUnit() {
        let actions = ProxyEgressRules.exitActions(
            enabled: true, networks: networks, wanInterface: "eth0", exitIP: "203.0.113.9")
        #expect(actions.map(\.id) == ["proxy-exit"])
        let command = actions[0].apply
        #expect(command.contains("vpn-chain-proxy-exit-rules.sh"))
        #expect(command.contains("vpn-chain-proxy-exit.service"))
        #expect(command.contains("systemctl restart vpn-chain-proxy-exit.service"))
    }

    // MARK: 4.1–4.2 — порядок применения, откат и выключение

    private func makeInput() throws -> ProvisioningInput {
        ProvisioningInput(
            s2Address: "203.0.113.9",
            obf: ObfuscationParams(
                jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 9, h2: 10, h3: 11, h4: 12),
            s1Keys: try WireGuardKeys.generateKeyPair(name: "s1-relay"),
            s2Keys: try WireGuardKeys.generateKeyPair(name: "s2-relay")
        )
    }

    @Test func engineAppliesExitThenEntry() async throws {
        let c1 = FakeRunner([])
        let c2 = FakeRunner([])
        let progress = LockedBox<[StepProgress]>([])
        let engine = ProvisioningEngine(
            c1: c1, c2: c2, input: try makeInput(),
            onProgress: { step in progress.withLock { $0.append(step) } })

        let applied = try await engine.applyProxyEgress(
            settings: ProxyEgressSettings(enabled: true, excludedNetworks: ["apps"]),
            allNetworks: networks,
            amneziaNetworks: [],
            exitIP: "203.0.113.9",
            wanInterface: "eth0",
            clientPort: "51820"
        )

        // Сначала выход (маршруты/NAT), затем вход (маркировка).
        #expect(c1.executed.first?.contains("vpn-chain-proxy-rules.sh") == true)
        #expect(c2.executed.first?.contains("vpn-chain-proxy-exit-rules.sh") == true)
        // Исключённая сеть не попадает в режим.
        #expect(applied.networks.map(\.name) == ["3x-ui"])
        let steps = progress.withLock { $0 }
        #expect(steps.contains { $0.stepID == "proxy-exit" && $0.state == .done })
        #expect(steps.contains { $0.stepID == "proxy-entry" && $0.state == .done })
    }

    @Test func engineRollsBackExitWhenEntryFails() async throws {
        let c1 = FakeRunner([
            ("vpn-chain-proxy-rules.sh", ok("", "iptables: permission denied", code: 1))
        ])
        let c2 = FakeRunner([])
        let progress = LockedBox<[StepProgress]>([])
        let engine = ProvisioningEngine(
            c1: c1, c2: c2, input: try makeInput(),
            onProgress: { step in progress.withLock { $0.append(step) } })

        await #expect(throws: ProvisioningError.self) {
            _ = try await engine.applyProxyEgress(
                settings: ProxyEgressSettings(enabled: true),
                allNetworks: networks,
                amneziaNetworks: [],
                exitIP: "203.0.113.9",
                wanInterface: "eth0",
                clientPort: nil
            )
        }

        // Откат: повторное применение на выходе в выключенном режиме (устаревшие сети снимаются).
        #expect(c2.executed.count == 2)
        #expect(c2.executed.last?.contains("SUBNETS=''") == true)
        let steps = progress.withLock { $0 }
        #expect(steps.contains { $0.stepID == "proxy-entry" && $0.state == .failed })
        #expect(steps.contains { $0.stepID == "proxy-disable" && $0.state == .done })
    }

    @Test func disableCommandRemovesRulesOnBothServers() async throws {
        let c1 = FakeRunner([])
        let c2 = FakeRunner([])
        let engine = ProvisioningEngine(c1: c1, c2: c2, input: try makeInput())

        let applied = try await engine.disableProxyEgress(wanInterface: "eth0")

        #expect(!applied.enabled)
        #expect(applied.networks.isEmpty)
        #expect(c2.executed.contains { $0.contains("vpn-chain-proxy-exit-rules.sh") })
        #expect(c1.executed.contains { $0.contains("vpn-chain-proxy-rules.sh") })
        // Отключение не трогает контейнер AmneziaVPN и SSH.
        let all = (c1.executed + c2.executed).joined(separator: "\n")
        #expect(!all.contains("docker stop"))
        #expect(!all.contains("docker rm"))
        #expect(!all.contains("amnezia-awg"))
    }

    // MARK: 4.3 — uninstall

    // MARK: 6.1–6.2 — диагностика режима

    @Test func proxyChecksAreHiddenWhenModeDisabled() {
        #expect(ChecksEngine.proxyChecks(state: nil).isEmpty)
        #expect(
            ChecksEngine.proxyChecks(state: ProxiesState(enabled: false, exitIP: nil, networks: []))
                .isEmpty)
    }

    @Test func proxyChecksCoverHostNetworksExitAndEgressIP() {
        let state = ProxiesState(
            enabled: true, exitIP: "203.0.113.9", networks: networks)
        let checks = ChecksEngine.proxyChecks(state: state)
        let ids = checks.map(\.id)
        #expect(
            ids == [
                "proxy-docker-networks", "proxy-nat-tunnel", "proxy-egress-ip",
            ])
        #expect(
            checks.first { $0.id == "proxy-docker-networks" }?.command.contains("br-aaaabbbbcccc")
                == true)
        // SNAT в туннель проверяется на сервере-входе (на выходе правил больше нет).
        let natCheck = checks.first { $0.id == "proxy-nat-tunnel" }
        #expect(natCheck?.server == .entry)
        #expect(
            natCheck?.kind
                == .outputContainsAll([
                    "-s 172.18.0.0/16 -o awg-relay -j MASQUERADE",
                    "-s 172.19.0.0/16 -o awg-relay -j MASQUERADE",
                ]))
        #expect(checks.first { $0.id == "proxy-egress-ip" }?.kind == .outputNotContains("MISMATCH"))
        let egress = checks.first { $0.id == "proxy-egress-ip" }
        // Проверка покрывает не только хост, но и контейнеры включённых сетей.
        #expect(egress?.command.contains("docker ps --filter 'network=3x-ui'") == true)
        #expect(egress?.command.contains("203.0.113.9") == true)
    }

    @Test func evaluatesMissingNetworkAndEgressIP() {
        let networkCheck = ServerCheck(
            id: "n", title: "n", command: "c", kind: .outputNotContains("MISSING"),
            failureHint: "дрейф", server: .entry)
        #expect(
            ChecksEngine.evaluate(
                networkCheck, result: SSHExecResult(exitCode: 0, stdout: "OK br-a\n", stderr: "")
            ).passed)
        #expect(
            !ChecksEngine.evaluate(
                networkCheck,
                result: SSHExecResult(exitCode: 0, stdout: "MISSING br-a\n", stderr: "")
            ).passed)

        let ipCheck = ServerCheck(
            id: "ip", title: "ip", command: "c", kind: .outputEquals("203.0.113.9"),
            failureHint: "не тот IP", server: .entry)
        #expect(
            ChecksEngine.evaluate(
                ipCheck, result: SSHExecResult(exitCode: 0, stdout: "203.0.113.9\n", stderr: "")
            ).passed)
        #expect(
            !ChecksEngine.evaluate(
                ipCheck, result: SSHExecResult(exitCode: 0, stdout: "198.51.100.1\n", stderr: "")
            ).passed)
    }

    @Test func troubleshootingHasProxySymptomsWithGuides() {
        let state = ProxiesState(enabled: true, exitIP: "203.0.113.9", networks: networks)
        for symptom in [Symptom.proxyNotEgressing, .accessLostAfterProxy] {
            let guide = Troubleshooting.guide(
                for: symptom, environment: nil, s2Address: "203.0.113.9", proxyState: state)
            #expect(!guide.title.isEmpty)
            #expect(!guide.explanation.isEmpty)
            #expect(!guide.advice.isEmpty)
        }
        let notEgressing = Troubleshooting.guide(
            for: .proxyNotEgressing, environment: nil, s2Address: nil, proxyState: state)
        #expect(notEgressing.checks.contains { $0.id == "proxy-nat-tunnel" })
        // Проверка хостового egress удалена вместе с самой функцией.
        #expect(!notEgressing.checks.contains { $0.id == "proxy-host-egress" })
        // Без состояния режима гайд подсказывает включить режим, а не падает.
        let withoutState = Troubleshooting.guide(
            for: .proxyNotEgressing, environment: nil, s2Address: nil)
        #expect(withoutState.checks.contains { $0.id == "proxy-state" })
    }

    @Test func uninstallCoversProxyArtifactsAndKeepsContainer() {
        let commands =
            UninstallPlan.entryCommands()
            + UninstallPlan.exitCommands(dockerSubnet: "172.26.0.0/16", clientSubnet: nil)
        let joined = commands.map(\.command).joined(separator: "\n")

        for artifact in [
            "vpn-chain-proxy.service", "vpn-chain-proxy-rules.sh",
            "vpn-chain-proxy-exit.service", "vpn-chain-proxy-exit-rules.sh",
            "VPNCHAIN_HOST_OUT", "VPNCHAIN_DOCKER_OUT", "proxies.json",
        ] {
            #expect(joined.contains(artifact), "артефакт режима не покрыт uninstall: \(artifact)")
        }
        // Удаление только своих артефактов: контейнер и SSH не затрагиваются.
        #expect(!joined.contains("docker stop"))
        #expect(!joined.contains("docker rm"))
        #expect(!joined.contains("amnezia-awg"))
        #expect(!joined.contains("iptables -P INPUT DROP"))
        // NAT на выходе удаляется по точному токену подсети, а не подстрокой:
        // иначе 10.0.0.0/16 совпало бы с 110.0.0.0/16.
        #expect(!joined.contains("index($0, s)"))
        #expect(joined.contains("index($0, \" -s \" s \" \")"))
        #expect(joined.contains("!index($0, \"! -o \")"))
    }
}
