import Foundation
import Testing
@testable import VPNChainCore

/// Тесты задачи 5.4: FSM-движок provisioning на фейковом транспорте.
///
/// ВАЖНО: сборка amneziawg-go выполняется на ОБОИХ серверах, поэтому go-фикстуры
/// (go.mod + go version) должны быть в очередях и С1, и С2 — иначе Go-решение
/// на С1 получит пустой вывод и упадёт с «go.mod нет директивы».
struct ProvisioningEngineTests {
    private let ubuntuFixture = "NAME=\"Ubuntu\"\nVERSION_ID=\"22.04\"\n---VPNCHAIN---\nx86_64"
    private let debianFixture = "NAME=\"Debian GNU/Linux\"\nVERSION_ID=\"12\"\n---VPNCHAIN---\nx86_64"
    private let handshakeOutput = """
    interface: awg-relay
      public key: abc=
      latest handshake: 47 seconds ago
      transfer: 1.2 MiB received, 3.4 MiB sent
    """

    private func makeInput() throws -> ProvisioningInput {
        ProvisioningInput(
            s2Address: "203.0.113.9",
            obf: ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 9, h2: 10, h3: 11, h4: 12),
            s1Keys: try WireGuardKeys.generateKeyPair(name: "s1-relay"),
            s2Keys: try WireGuardKeys.generateKeyPair(name: "s2-relay")
        )
    }

    /// Детект окружения (docker) — обязателен для любого прогона движка.
    private func detectScript() -> [(contains: String, result: Result<SSHExecResult, Error>)] {
        [
            ("docker ps", ok(DockerFixtures.containerNames)),
            ("NetworkSettings.Networks", ok(DockerFixtures.containerNetworks)),
            ("docker network inspect", ok(DockerFixtures.networkInspect)),
            ("wg0.conf", ok(DockerFixtures.wg0Conf)),
        ]
    }

    /// Свежий Go на сервере (go.mod 1.25.0 ↔ system go1.25.0 — systemSufficient).
    private func goSufficientScript() -> [(contains: String, result: Result<SSHExecResult, Error>)] {
        [
            ("go.mod", ok("go 1.25.0")),
            ("go version", ok("go version go1.25.0 linux/amd64")),
        ]
    }

    @Test func handshakeSeenParser() {
        #expect(ProvisioningEngine.handshakeSeen("interface: awg-relay\n  latest handshake: 2 minutes ago"))
        #expect(!ProvisioningEngine.handshakeSeen("interface: awg-relay\n"))
        #expect(!ProvisioningEngine.handshakeSeen(""))
    }

    @Test func parseExistingStateFromMarkerOutput() throws {
        let output = """
        ==VPNCHAIN-FILE s1-relay.key==
        AAAA
        ==VPNCHAIN-FILE s1-relay.pub==
        AAAA
        ==VPNCHAIN-FILE s2-relay.key==
        AAAA
        ==VPNCHAIN-FILE s2-relay.pub==
        AAAA
        ==VPNCHAIN-FILE obf.conf==
        Jc=5
        Jmin=8
        Jmax=80
        S1=100
        S2=77
        H1=9
        H2=10
        H3=11
        H4=12
        """
        // Все маркеры распознаны, файлы найдены → падение на формате ключа, а не missingFile.
        #expect(throws: ChainStateParser.StateError.invalidKeyFormat("s1-relay.key: не base64 длиной 32 байта")) {
            try ProvisioningEngine.parseExistingState(output, environment: ChainState.Environment(
                bridge: "b", dockerSubnet: "s", containerIP: "i"
            ))
        }
    }

    @Test func happyPathOrderC2BeforeC1() async throws {
        let input = try makeInput()
        let c1 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("awg show", ok(handshakeOutput)),
        ])
        let c2 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("ip route show", ok("default via 10.0.0.1 dev eth0 proto dhcp metric 100")),
        ])
        let engine = ProvisioningEngine(c1: c1, c2: c2, input: input, options: .init(verifyAttempts: 2, verifyDelay: 0.01))

        let environment = try await engine.run()

        // Окружение из детекта.
        #expect(environment.bridge == "br-9f7e5c1a2b3d")
        #expect(environment.dockerSubnet == "172.26.0.0/16")
        #expect(environment.containerIP == "172.26.0.2")

        // Порядок: установка С2 началась раньше С1 (probe platform — первый шаг install).
        let c2Probe = c2.executed.firstIndex { $0.contains("os-release") }
        let c1Probe = c1.executed.firstIndex { $0.contains("os-release") }
        #expect(c2Probe != nil && c1Probe != nil && c2Probe! < c1Probe!)

        // Конфигурация С2 раньше С1 (доставка awg-relay.conf).
        let c2Config = c2.executed.firstIndex { $0.contains("awg-relay.conf") }
        let c1Config = c1.executed.firstIndex { $0.contains("awg-relay.conf") }
        #expect(c2Config != nil && c1Config != nil && c2Config! < c1Config!)

        // Состояние разложено на С1.
        let stateDelivery = c1.executed.contains { $0.contains("/etc/amnezia/chain/s1-relay.key") }
        #expect(stateDelivery)

        // Handshake-проверка выполнялась на С1.
        #expect(c1.executed.contains { $0.contains("awg show awg-relay") })
    }

    @Test func resumeSkipsCompletedInstall() async throws {
        let input = try makeInput()
        let c1 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("awg show", ok(handshakeOutput)),
        ])
        let c2 = FakeRunner([
            ("os-release", ok(ubuntuFixture)),
            ("ip route show", ok("default via 10.0.0.1 dev eth0")),
        ])

        let engine = ProvisioningEngine(c1: c1, c2: c2, input: input, options: .init(verifyAttempts: 1, verifyDelay: 0.01))
        _ = try await engine.run(completedSteps: ["install-c2"])

        // install-c2 пропущен: на С2 не было probe платформы.
        #expect(!c2.executed.contains { $0.contains("os-release") })
        // Но configure-c2 всё равно применился (не в completedSteps).
        #expect(c2.executed.contains { $0.contains("awg-relay.conf") })
        // Detect выполнен всегда.
        #expect(c1.executed.contains { $0.contains("docker ps") })
    }

    @Test func failureStopsEngineWithFailedProgress() async throws {
        let input = try makeInput()
        let c1 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("awg show", ok(handshakeOutput)),
        ])
        let c2 = FakeRunner(detectScript() + goSufficientScript() + [
            ("command -v git", ok("", code: 1)), // force deps apply
            ("apt-get install", ok("", "boom: не удалось установить", code: 1)),
            ("os-release", ok(ubuntuFixture)),
            ("journalctl -u awg-quick@awg-relay", ok("awg-quick[1234]: name or service not known")), // журнал юнита при падении
        ])

        let progressBox = LockedBox<[StepProgress]>([])
        let engine = ProvisioningEngine(
            c1: c1,
            c2: c2,
            input: input,
            options: .init(verifyAttempts: 1, verifyDelay: 0.01),
            onProgress: { step in progressBox.withLock { $0.append(step) } }
        )

        do {
            _ = try await engine.run()
            Issue.record("Ожидалась ошибка командного шага")
        } catch let error as ProvisioningError {
            guard case .commandFailed(let step, _, let stderr) = error else {
                Issue.record("Ожидался commandFailed, получено: \(error)")
                return
            }
            #expect(step == "deps")
            #expect(stderr.contains("boom"))
        } catch {
            Issue.record("Неожиданный тип: \(error)")
        }

        let events = progressBox.withLock { $0 }
        #expect(events.contains { $0.stepID == "install-c2" && $0.state == .failed })
        // Движок остановился: до configure-c2 не дошло.
        #expect(!events.contains { $0.stepID == "configure-c2" && $0.state == .running })
        // Порядок шагов до сбоя: detect-c1 → install-c2.
        #expect(events.contains { $0.stepID == "detect-c1" && $0.state == .done })
    }

    @Test func verifyFailsAfterAttemptsExhausted() async throws {
        let input = try makeInput()
        let c1 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("awg show", ok("interface: awg-relay\n")), // handshake нет
        ])
        let c2 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("ip route show", ok("default dev eth0")),
        ])

        let engine = ProvisioningEngine(c1: c1, c2: c2, input: input, options: .init(verifyAttempts: 2, verifyDelay: 0.01))
        do {
            _ = try await engine.run()
            Issue.record("Ожидался handshakeNotSeen")
        } catch let error as ProvisioningEngine.VerifyError {
            #expect(error == .handshakeNotSeen(attempts: 2))
        } catch {
            Issue.record("Неожиданный тип: \(error)")
        }
    }

    /// Регрессия приёмки: клиентский трафик выходит на хост через интерфейс контейнера
    /// (amn0). Отбор трафика — по метке с исключением ответов клиентам, а НЕ по iif:
    /// правило `iif` ломало handshake клиента (ответы контейнера уходили в туннель).
    @Test func ingressInterfaceFromRouteGet() async throws {
        let input = try makeInput()
        let c1 = FakeRunner(detectScript() + [
            ("ip route get 172.26.0.2", ok("172.26.0.2 dev amn0 src 172.26.0.1 uid 0\n    cache")),
        ] + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("awg show", ok(handshakeOutput)),
        ])
        let c2 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("ip route show", ok("default via 10.0.0.1 dev eth0")),
        ])
        let engine = ProvisioningEngine(c1: c1, c2: c2, input: input, options: .init(verifyAttempts: 1, verifyDelay: 0.01))
        let environment = try await engine.run()

        // Окружение: интерфейс входа — amn0, а не br-…; порт клиентского AWG определён.
        #expect(environment.bridge == "amn0")
        #expect(environment.clientPort == "51820")
        // Правила С1: метка + исключение ответов клиентам, без iif.
        #expect(c1.executed.contains { $0.contains("BRIDGE='amn0'") })
        #expect(c1.executed.contains { $0.contains("ip rule add fwmark \"$MARK\" table 51821 priority 100") })
        #expect(c1.executed.contains { $0.contains("--sport \"$CLIENT_PORT\" -j RETURN") })
        #expect(!c1.executed.contains { $0.contains("ip rule add iif") })
    }

    /// Регрессия приёмки: без порта клиентского AWG правила не применяются —
    /// иначе легко снова увести ответы клиентам в туннель.
    @Test func missingClientPortFailsBeforeRules() async throws {
        let input = try makeInput()
        // Конфиг без ListenPort.
        let noPortConf = "[Interface]\nAddress = 10.8.1.5/24\n"
        let c1 = FakeRunner([
            ("docker ps", ok(DockerFixtures.containerNames)),
            ("NetworkSettings.Networks", ok(DockerFixtures.containerNetworks)),
            ("docker network inspect", ok(DockerFixtures.networkInspect)),
            ("wg0.conf", ok(noPortConf)),
        ] + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
        ])
        let c2 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("ip route show", ok("default via 10.0.0.1 dev eth0")),
        ])

        let engine = ProvisioningEngine(c1: c1, c2: c2, input: input, options: .init(verifyAttempts: 1, verifyDelay: 0.01))
        do {
            _ = try await engine.run()
            Issue.record("Ожидалась ошибка об отсутствии порта клиентского AWG")
        } catch let error as ProvisioningError {
            if case .parseFailed(let message) = error {
                #expect(message.contains("порт клиентского AWG"), "получено сообщение: \(message)")
            } else {
                Issue.record("Неожиданная ошибка: \(error)")
            }
        }
        // Опасные правила не применялись.
        #expect(!c1.executed.contains { $0.contains("ip rule add fwmark") })
        #expect(!c1.executed.contains { $0.contains("VPNCHAIN_MARK") })
    }

    /// Регрессия: контейнер на дефолтном bridge → детект мигрирует его на выделенную
    /// сеть со свободной подсетью, и установка продолжается уже от новой сети.
    @Test func bridgeMigrationDuringDetect() async throws {
        let input = try makeInput()
        let bridgeNetworks = #"{"bridge":{"IPAddress":"172.17.0.2"}}"#
        let relayNetworks = #"{"amnezia-relay-net":{"IPAddress":"172.29.172.2"}}"#
        let relayInspect = #"{"Id":"aaaabbbbccccdddd0000111122223333444455556666777788889999aaaabbbb","IPAM":{"Config":[{"Subnet":"172.29.172.0/24"}]}}"#
        let routes = "default via 10.0.0.1 dev eth0\n172.17.0.0/16 dev docker0 proto kernel scope link"

        let c1 = FakeRunner([
            ("docker ps", ok("amnezia-awg2\n")),
            ("NetworkSettings.Networks", ok(bridgeNetworks)),  // первая инспекция: дефолтный bridge
            ("ip -4 route show", ok(routes)),                  // маршруты С1 для выбора подсети
            ("docker network create", ok("")),                 // миграция
            ("NetworkSettings.Networks", ok(relayNetworks)),   // повторная инспекция: relay
            ("docker network inspect", ok(relayInspect)),      // инспекция новой сети
            ("wg0.conf", ok(DockerFixtures.wg0Conf)),
        ] + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("awg show", ok(handshakeOutput)),
        ])
        let c2 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("ip -4 route show", ok(routes)),                  // маршруты С2 для выбора подсети
            ("ip route show", ok("default via 10.0.0.1 dev eth0")), // WAN detect
            ("awg show", ok(handshakeOutput)),
        ])
        let progressBox = LockedBox<[StepProgress]>([])
        let engine = ProvisioningEngine(
            c1: c1,
            c2: c2,
            input: input,
            options: .init(verifyAttempts: 1, verifyDelay: 0.01),
            onProgress: { step in progressBox.withLock { $0.append(step) } }
        )

        let environment = try await engine.run()

        // Окружение пересчитано по выделенной сети.
        #expect(environment.bridge == "br-aaaabbbbcccc")
        #expect(environment.dockerSubnet == "172.29.172.0/24")
        #expect(environment.containerIP == "172.29.172.2")

        // Миграция выполнена на С1: создание сети + отключение от bridge.
        #expect(c1.executed.contains { $0.contains("docker network create --subnet='172.29.172.0/24' amnezia-relay-net") })
        #expect(c1.executed.contains { $0.contains("docker network disconnect bridge amnezia-awg2") })

        // Отчёт шага detect-c1 сообщает о переносе.
        let detectDone = progressBox.withLock { $0 }.first { $0.stepID == "detect-c1" && $0.state == .done }
        #expect(detectDone?.detail?.contains("перенесён") == true)
    }

    /// Регрессия: юнит vpn-chain-exit содержит awg-quick@awg-relay в строке After= —
    /// диагностика не должна вытягивать чужой журнал по неспецифичному матчингу.
    @Test func failureDiagnosticsTargetsCorrectUnit() {
        let rulesAction = ConfigureC2.actions(configContent: "[Interface]", wanInterface: "eth0", dockerSubnet: "172.26.0.0/16", clientSubnet: nil)
            .first { $0.id == "c2-rules" }!
        let diagnostics = ProvisioningEngine.failureDiagnosticsCommand(for: rulesAction)
        // Трассировка упавшего скрипта + журнал правильных юнитов.
        #expect(diagnostics.contains("bash -x /usr/local/bin/vpn-chain-exit-rules.sh"))
        #expect(diagnostics.contains("journalctl -u vpn-chain.service -u vpn-chain-exit.service"))
        // Чужой юнит не вытягивается через строку After=.
        #expect(!diagnostics.contains("journalctl -u awg-quick@awg-relay"))
    }

    /// Регрессия приёмки: Go-решение обязано выполняться ПОСЛЕ клона amneziawg-go
    /// (grep go.mod до клона возвращал пусто → fallback пропускался → «go: not found»).
    @Test func goDecisionRunsAfterCloneAndFallbackApplied() async throws {
        let input = try makeInput()
        let c1 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("awg show", ok(handshakeOutput)),
        ])
        // Системный Go 1.19 старее требуемого (go.mod pinned-репозитория: 1.25.0) → fallback.
        let c2 = FakeRunner(detectScript() + [
            ("os-release", ok(debianFixture)),
            ("amneziawg-go/.git", ok("", code: 1)), // форсируем клон (check неуспешен)
            ("go.mod", ok("go 1.25.0")),
            ("go version", ok("go version go1.19 linux/amd64")),
            ("ip route show", ok("default via 10.0.0.1 dev eth0")),
            ("awg show", ok(handshakeOutput)),
        ])
        let engine = ProvisioningEngine(c1: c1, c2: c2, input: input, options: .init(verifyAttempts: 1, verifyDelay: 0.01))
        _ = try await engine.run()

        let cloneIndex = c2.executed.firstIndex { $0.contains("git clone https://github.com/amnezia-vpn/amneziawg-go") }
        let grepIndex = c2.executed.firstIndex { $0.contains("grep") && $0.contains("go.mod") }
        #expect(cloneIndex != nil, "клон amneziawg-go должен был выполниться")
        #expect(grepIndex != nil, "grep go.mod должен был выполниться")
        #expect(grepIndex! > cloneIndex!, "Go-решение обязано идти после клона, получено: clone=\(cloneIndex!), grep=\(grepIndex!)")

        // Fallback-установка go1.25.0 выполнена после решения.
        let tarballIndex = c2.executed.firstIndex { $0.contains("go1.25.0.linux-amd64.tar.gz") }
        if tarballIndex == nil {
            var dump = "tarball go1.25.0 не скачан; выполнено на С2:\n"
            for (index, command) in c2.executed.enumerated() {
                dump += "\(index): \(command)\n"
            }
            Issue.record("\(dump)")
        }
        #expect(tarballIndex != nil)
        #expect(tarballIndex! > grepIndex!)
    }

    /// Регрессия повторного прогона: go-source пропущен по check'у (репозиторий уже
    /// на месте), но Go-решение обязано выполниться и поставить fallback для старого Go.
    @Test func goDecisionRunsEvenWhenCloneSkipped() async throws {
        let input = try makeInput()
        let c1 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("awg show", ok(handshakeOutput)),
        ])
        let c2 = FakeRunner(detectScript() + [
            ("os-release", ok(debianFixture)),
            // go-source check УСПЕШЕН (репозиторий уже склонирован) → шаг пропускается.
            ("go.mod", ok("go 1.25.0")),
            ("go version", ok("go version go1.19 linux/amd64")),
            ("ip route show", ok("default via 10.0.0.1 dev eth0")),
            ("awg show", ok(handshakeOutput)),
        ])
        let engine = ProvisioningEngine(c1: c1, c2: c2, input: input, options: .init(verifyAttempts: 1, verifyDelay: 0.01))
        _ = try await engine.run()

        // Fallback применён несмотря на пропуск клона.
        let tarballIndex = c2.executed.firstIndex { $0.contains("go1.25.0.linux-amd64.tar.gz") }
        #expect(tarballIndex != nil, "fallback Go не установлен при пропущенном клоне")

        // Решение после grep go.mod.
        let grepIndex = c2.executed.firstIndex { $0.contains("grep") && $0.contains("go.mod") }
        #expect(grepIndex != nil && tarballIndex! > grepIndex!)
    }

    /// Если go.mod не распознан — установка падает сразу с понятной ошибкой, а не доходит до сборки.
    @Test func invalidGoModFailsFast() async throws {
        let input = try makeInput()
        let c1 = FakeRunner(detectScript() + goSufficientScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("awg show", ok(handshakeOutput)),
        ])
        let c2 = FakeRunner(detectScript() + [
            ("os-release", ok(ubuntuFixture)),
            ("amneziawg-go/.git", ok("", code: 1)),
            ("go.mod", ok("module github.com/amnezia-vpn/amneziawg-go/v3")), // без директивы go
            ("ip route show", ok("default dev eth0")),
            ("awg show", ok(handshakeOutput)),
        ])
        let engine = ProvisioningEngine(c1: c1, c2: c2, input: input, options: .init(verifyAttempts: 1, verifyDelay: 0.01))
        do {
            _ = try await engine.run()
            Issue.record("Ожидалась ошибка go.mod")
        } catch let error as ProvisioningError {
            guard case .parseFailed(let detail) = error, detail.contains("go.mod") else {
                Issue.record("Ожидался parseFailed(go.mod), получено: \(error)")
                return
            }
        } catch {
            Issue.record("Неожиданный тип: \(error)")
        }
    }
}
