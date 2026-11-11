import Foundation
import Testing
@testable import VPNChainCore

/// Каркасный тест: проверяет работоспособность тестовой инфраструктуры.
struct ScaffoldTests {
    @Test func serverRolesPresent() {
        #expect(ServerRole.allCases.count == 2)
        #expect(ServerRole.allCases.contains(.entry))
        #expect(ServerRole.allCases.contains(.exit))
    }

    @Test func roleCodableRoundtrip() throws {
        let encoded = try JSONEncoder().encode(ServerRole.entry)
        let decoded = try JSONDecoder().decode(ServerRole.self, from: encoded)
        #expect(decoded == .entry)
    }
}
