import Foundation
import Testing
@testable import VPNChainCore

/// Фикстуры вывода `awg show awg-relay`.
enum AwgShowFixtures {
    static let withHandshake = """
    interface: awg-relay
      public key: abcd=
      listening port: 51820
    peer: ef01=
      endpoint: 203.0.113.9:51828
      allowed ips: 0.0.0.0/0
      latest handshake: 47 seconds ago
      transfer: 1.2 MiB received, 980 KiB sent
      persistent keepalive: every 25 seconds
    """

    static let staleHandshake = """
    interface: awg-relay
      latest handshake: 5 minutes, 30 seconds ago
      transfer: 10 MiB received, 20 MiB sent
    """

    static let noHandshake = """
    interface: awg-relay
      listening port: 51820
    """

    static let notOurInterface = """
    interface: wg0
      listening port: 51820
    """
}

/// Тесты задачи 6.1: парсеры статуса.
struct StatusParserTests {
    @Test func relayStatusFullParse() {
        let status = StatusParsers.parseRelayStatus(AwgShowFixtures.withHandshake)
        #expect(status.interfaceUp)
        #expect(status.handshakeSecondsAgo == 47)
        #expect(status.rxBytes == Int64(1.2 * 1024 * 1024))
        #expect(status.txBytes == Int64(980 * 1024))
    }

    @Test func handshakeAgeVariants() {
        #expect(StatusParsers.parseHandshakeAge("47 seconds ago") == 47)
        #expect(StatusParsers.parseHandshakeAge("2 minutes, 30 seconds ago") == 150)
        #expect(StatusParsers.parseHandshakeAge("1 hour, 5 minutes ago") == 3900)
        #expect(StatusParsers.parseHandshakeAge("3 days, 4 hours ago") == 3 * 86_400 + 4 * 3600)
        #expect(StatusParsers.parseHandshakeAge("внезапно") == nil)
        #expect(StatusParsers.parseHandshakeAge("2 minutes, 30 seconds") == nil) // без "ago"
    }

    @Test func relayStatusStaleAndMissing() {
        let stale = StatusParsers.parseRelayStatus(AwgShowFixtures.staleHandshake)
        #expect(stale.handshakeSecondsAgo == 330)
        #expect(stale.rxBytes == Int64(10 * 1024 * 1024))

        let missing = StatusParsers.parseRelayStatus(AwgShowFixtures.noHandshake)
        #expect(missing.interfaceUp)
        #expect(missing.handshakeSecondsAgo == nil)
        #expect(missing.rxBytes == nil)
    }

    @Test func foreignInterfaceNotOurs() {
        #expect(!StatusParsers.parseRelayStatus(AwgShowFixtures.notOurInterface).interfaceUp)
    }

    @Test func ipRuleParsing() {
        let present = "0:\tfrom all lookup local\n100:\tfrom all fwmark 0x51 lookup 51821\n32766:\tfrom all lookup main"
        #expect(StatusParsers.parseIpRule(present))
        // Старая схема (iif) тоже распознаётся.
        #expect(StatusParsers.parseIpRule("100:\tiif \"br-9f7e5c1a2b3d\" lookup 51821"))
        #expect(!StatusParsers.parseIpRule("0:\tfrom all lookup local\n32766:\tfrom all lookup main"))
    }

    @Test func routeTableParsing() {
        let full = "default dev awg-relay scope link\nblackhole default metric 42760"
        let parsed = StatusParsers.parseRouteTable(full)
        #expect(parsed.defaultViaRelay)
        #expect(parsed.blackhole)
        let broken = StatusParsers.parseRouteTable("blackhole default metric 42760")
        #expect(!broken.defaultViaRelay && broken.blackhole)
    }

    @Test func dockerUserJumpParsing() {
        #expect(StatusParsers.parseDockerUserJump("-P DOCKER-USER ACCEPT\n-A DOCKER-USER -j VPNCHAIN\n-A DOCKER-USER -j RETURN"))
        #expect(!StatusParsers.parseDockerUserJump("-A DOCKER-USER -j RETURN"))
    }

    @Test func listeningPortParsing() {
        let output = "Netid State Recv-Q Send-Q Local Address:Port\nudp   UNCONN 0      0      0.0.0.0:51828 0.0.0.0:*"
        #expect(StatusParsers.parseListeningPort(output))
        #expect(!StatusParsers.parseListeningPort("udp UNCONN 0 0 0.0.0.0:51820 0.0.0.0:*"))
    }
    @Test func masqueradeParsing() {
        let output = "-A POSTROUTING -s 172.26.0.0/16 -o eth0 -j MASQUERADE"
        #expect(StatusParsers.parseMasquerade(output, subnet: "172.26.0.0/16"))
        #expect(!StatusParsers.parseMasquerade(output, subnet: "10.8.1.0/24"))
        #expect(!StatusParsers.parseMasquerade("-A POSTROUTING -o eth0 -j MASQUERADE", subnet: "172.26.0.0/16"))
    }
}

/// Тесты задачи 6.2: движок проверок и ручной чек-лист.
struct ChecksEngineTests {
    @Test func evaluateContains() {
        let check = ServerCheck(id: "x", title: "t", command: "c", kind: .outputContains("abc"), failureHint: "hint", server: .entry)
        #expect(ChecksEngine.evaluate(check, result: SSHExecResult(exitCode: 0, stdout: "xx abc yy", stderr: "")).passed)
        let failed = ChecksEngine.evaluate(check, result: SSHExecResult(exitCode: 0, stdout: "nope", stderr: ""))
        #expect(!failed.passed)
        #expect(failed.hint == "hint")
    }

    @Test func evaluateHandshakeWindow() {
        let check = ServerCheck(id: "h", title: "t", command: "c", kind: .handshakeWithin(seconds: 180), failureHint: "stale", server: .entry)
        #expect(ChecksEngine.evaluate(check, result: SSHExecResult(exitCode: 0, stdout: AwgShowFixtures.withHandshake, stderr: "")).passed)
        let stale = ChecksEngine.evaluate(check, result: SSHExecResult(exitCode: 0, stdout: AwgShowFixtures.staleHandshake, stderr: ""))
        #expect(!stale.passed)
        #expect(stale.hint?.contains("330 c назад") == true)
        let missing = ChecksEngine.evaluate(check, result: SSHExecResult(exitCode: 0, stdout: AwgShowFixtures.noHandshake, stderr: ""))
        #expect(!missing.passed)
        #expect(missing.hint?.contains("не зафиксирован") == true)
    }

    @Test func automatedChecksIncludeAllSections() throws {
        let env = ChainState.Environment(
            bridge: "br-1",
            dockerSubnet: "172.26.0.0/16",
            containerIP: "172.26.0.2",
            containerName: "amnezia-awg"
        )
        let checks = ChecksEngine.automatedChecks(environment: env)
        let ids = checks.map { $0.id }
        for id in ["handshake", "policy-rule", "kill-switch", "docker-user", "container-untouched", "exit-relay", "exit-port", "exit-nat"] {
            #expect(ids.contains(id), "нет проверки \(id)")
        }
        // Каждая проверка с подсказкой при провале.
        #expect(checks.allSatisfy { !$0.failureHint.isEmpty })
        // NAT-проверка знает подсеть (в условиях оценки, а не в самой команде).
        let nat = checks.first { $0.id == "exit-nat" }
        #expect(nat?.kind == .outputContains("-s 172.26.0.0/16"))
    }

    @Test func manualChecklistCoversTZ10ManualItems() {
        let ids = ManualChecklist.items.map { $0.id }
        // Пункты 7–9 (клиент) и 11–12 (reboot, kill-switch) ТЗ.
        for id in ["client-ip", "dns-leak", "ipv6", "reboot", "kill-switch"] {
            #expect(ids.contains(id))
        }
    }
}

/// Тесты задачи 6.3: гайды по симптомам.
struct TroubleshootingTests {
    private let env = ChainState.Environment(
        bridge: "br-9f7e5c1a2b3d",
        dockerSubnet: "172.26.0.0/16",
        containerIP: "172.26.0.2",
        containerName: "amnezia-awg"
    )

    @Test func allSymptomsHaveGuides() {
        for symptom in Symptom.allCases {
            let guide = Troubleshooting.guide(for: symptom, environment: env, s2Address: "203.0.113.9")
            #expect(!guide.title.isEmpty)
            #expect(!guide.explanation.isEmpty)
            #expect(!guide.advice.isEmpty, "симптом \(symptom) без советов")
        }
    }

    @Test func noHandshakeChecksUDPPortAndObfuscation() {
        let guide = Troubleshooting.guide(for: .noHandshake, environment: env, s2Address: "203.0.113.9")
        #expect(guide.checks.contains { $0.command.contains("nc -uvz -w 3 203.0.113.9 51828") })
        #expect(guide.checks.contains { $0.command.contains("awg showconf awg-relay") })
        // Совет про порт провайдера — первый.
        #expect(guide.advice[0].contains("UDP 51828"))
    }

    @Test func dockerNetworkRecreatedSuggestsReapply() {
        let guide = Troubleshooting.guide(for: .dockerNetworkRecreated, environment: env, s2Address: nil)
        #expect(guide.suggestsReapply)
        #expect(guide.checks.contains { $0.kind == .outputContains("172.26.0.0/16") })
    }

    @Test func sshLostContainsRescueCommand() {
        let guide = Troubleshooting.guide(for: .sshLost, environment: env, s2Address: nil)
        #expect(guide.advice.contains { $0.contains("while ip rule del table 51821") })
        #expect(guide.checks.isEmpty) // SSH недоступен — автоматических проверок нет
    }

    @Test func brokenAfterUserAddedIsNormal() {
        let guide = Troubleshooting.guide(for: .brokenAfterAppUserAdded, environment: env, s2Address: nil)
        #expect(guide.advice.contains { $0.contains("ожидаемое поведение") })
        #expect(!guide.suggestsReapply)
    }

    @Test func noHandshakeWithoutAddressSkipsUDPCheck() {
        let guide = Troubleshooting.guide(for: .noHandshake, environment: env, s2Address: nil)
        #expect(!guide.checks.contains { $0.command.contains("nc -uvz") })
    }
}
