import Foundation
import Testing
@testable import VPNChainCore

/// Тесты задачи 3.3: парсер и валидатор состояния `/etc/amnezia/chain/`.
struct ChainStateParserTests {
    private func validFiles() throws -> [String: String] {
        let s1 = try WireGuardKeys.generateKeyPair(name: "s1-relay")
        let s2 = try WireGuardKeys.generateKeyPair(name: "s2-relay")
        let obf = ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 9, h2: 10, h3: 11, h4: 12)
        return [
            "s1-relay.key": s1.privateKey,
            "s1-relay.pub": s1.publicKey,
            "s2-relay.key": s2.privateKey,
            "s2-relay.pub": s2.publicKey,
            "obf.conf": obf.ordered.map { "\($0.name)=\($0.value)" }.joined(separator: "\n"),
            "env": """
            BRIDGE=br-4a2b9
            DOCKER_SUBNET=172.26.0.0/16
            CONTAINER_IP=172.26.0.2
            CLIENT_SUBNET=10.8.1.0/24
            COMMIT=abc1234
            """,
        ]
    }

    @Test func validStateParses() throws {
        let state = try ChainStateParser.parse(files: validFiles())
        #expect(state.environment.bridge == "br-4a2b9")
        #expect(state.environment.dockerSubnet == "172.26.0.0/16")
        #expect(state.environment.containerIP == "172.26.0.2")
        #expect(state.environment.clientSubnet == "10.8.1.0/24")
        #expect(state.environment.commit == "abc1234")
        #expect(ObfuscationRules.validate(state.obf).isEmpty)
    }

    @Test func missingFileIsReported() throws {
        var files = try validFiles()
        files.removeValue(forKey: "s2-relay.pub")
        #expect(throws: ChainStateParser.StateError.missingFile("s2-relay.pub")) {
            try ChainStateParser.parse(files: files)
        }
    }

    @Test func publicKeyMismatchIsReported() throws {
        var files = try validFiles()
        let foreign = try WireGuardKeys.generateKeyPair(name: "other")
        files["s2-relay.pub"] = foreign.publicKey
        #expect(throws: ChainStateParser.StateError.publicKeyMismatch("s2-relay.pub не соответствует приватному ключу")) {
            try ChainStateParser.parse(files: files)
        }
    }

    @Test func invalidKeyFormatIsReported() throws {
        var files = try validFiles()
        files["s1-relay.key"] = "битый-ключ"
        do {
            _ = try ChainStateParser.parse(files: files)
            Issue.record("Ожидался invalidKeyFormat")
        } catch let error as ChainStateParser.StateError {
            guard case .invalidKeyFormat = error else {
                Issue.record("Ожидался invalidKeyFormat, получено: \(error)")
                return
            }
        }
    }

    @Test func s2CollisionInStateIsReported() throws {
        var files = try validFiles()
        files["obf.conf"] = """
        Jc=5
        Jmin=8
        Jmax=80
        S1=100
        S2=156
        H1=9
        H2=10
        H3=11
        H4=12
        """
        do {
            _ = try ChainStateParser.parse(files: files)
            Issue.record("Ожидался invalidParams")
        } catch let error as ChainStateParser.StateError {
            guard case .invalidParams = error else {
                Issue.record("Ожидался invalidParams, получено: \(error)")
                return
            }
        }
    }

    @Test func duplicateHInStateIsReported() throws {
        var files = try validFiles()
        files["obf.conf"] = "Jc=5\nJmin=8\nJmax=80\nS1=100\nS2=77\nH1=9\nH2=9\nH3=11\nH4=12"
        #expect(throws: ChainStateParser.StateError.invalidParams("obf.conf: нарушение правила hValuesNotDistinct")) {
            try ChainStateParser.parse(files: files)
        }
    }

    @Test func envWithoutBridgeIsReported() throws {
        var files = try validFiles()
        files["env"] = "DOCKER_SUBNET=172.26.0.0/16\nCONTAINER_IP=172.26.0.2"
        #expect(throws: ChainStateParser.StateError.invalidEnvironment("env: BRIDGE отсутствует")) {
            try ChainStateParser.parse(files: files)
        }
    }

    @Test func clientSubnetIsOptional() throws {
        var files = try validFiles()
        files["env"] = "BRIDGE=br-1\nDOCKER_SUBNET=172.26.0.0/16\nCONTAINER_IP=172.26.0.2"
        let state = try ChainStateParser.parse(files: files)
        #expect(state.environment.clientSubnet == nil)
    }
}
