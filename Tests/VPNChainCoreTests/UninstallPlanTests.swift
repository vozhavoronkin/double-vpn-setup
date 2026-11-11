import Foundation
import Testing
@testable import VPNChainCore

/// Тесты задачи 6.4: план uninstall против инвентаря установки.
struct UninstallPlanTests {
    private func joinedCommands() -> String {
        let entry = UninstallPlan.entryCommands()
        let exit = UninstallPlan.exitCommands(dockerSubnet: "172.26.0.0/16", clientSubnet: "10.8.1.0/24")
        return (entry + exit).map { $0.command }.joined(separator: "\n")
    }

    @Test func inventoryFullyCoveredByCommands() {
        let joined = joinedCommands()
        for artifact in UninstallPlan.inventory {
            #expect(joined.contains(artifact), "инвентарный артефакт не покрыт uninstall'ом: \(artifact)")
        }
    }

    @Test func forbiddenTargetsNotTouched() {
        let joined = joinedCommands()
        // Контейнер AmneziaVPN не останавливается и не удаляется.
        #expect(!joined.contains("docker stop"))
        #expect(!joined.contains("docker rm"))
        #expect(!joined.contains("amnezia-awg"))
        #expect(!joined.contains("/opt/amnezia"))
        // SSH не блокируется.
        #expect(!joined.contains("iptables -P INPUT DROP"))
        #expect(!joined.contains("iptables -P FORWARD DROP"))
        // Собранное ПО не удаляется в основном плане.
        #expect(!joined.contains("rm -f /usr/bin/awg"))
        #expect(!joined.contains("apt-get remove"))
    }

    @Test func entryCommandsRemoveAllManagedArtifacts() {
        let commands = UninstallPlan.entryCommands()
        let ids = commands.map { $0.id }
        for id in ["entry-stop", "entry-routing", "entry-firewall", "entry-files", "entry-state"] {
            #expect(ids.contains(id))
        }
        let joined = commands.map { $0.command }.joined(separator: "\n")
        // Идемпотентность: всё с guard'ами.
        #expect(joined.contains("2>/dev/null || true"))
        // Routing удаляется целиком: все правила таблицы + mangle-цепочка маркировки.
        #expect(joined.contains("while ip rule del table 51821 2>/dev/null; do :; done"))
        #expect(joined.contains("iptables -t mangle -X VPNCHAIN_MARK"))
        #expect(joined.contains("ip route flush table 51821"))
        // Состояние и конфиги удалены.
        #expect(joined.contains("rm -rf '/etc/amnezia/chain'"))
        #expect(joined.contains("awg-relay.conf.bak."))
        #expect(joined.contains("rm -f '/etc/sysctl.d/99-vpn-chain.conf'"))
    }

    @Test func exitCommandsRemoveNatForBothSubnets() {
        let commands = UninstallPlan.exitCommands(dockerSubnet: "172.26.0.0/16", clientSubnet: "10.8.1.0/24")
        let joined = commands.map { $0.command }.joined(separator: "\n")
        // Удаление всех MASQUERADE по подсетям (правила создаются с `-o <WAN>`,
        // поэтому удаляем по номеру правила).
        #expect(joined.contains("'172.26.0.0/16'"))
        #expect(joined.contains("'10.8.1.0/24'"))
        #expect(joined.contains("'10.99.0.0/24'"))
        #expect(joined.contains("/MASQUERADE/"))
        #expect(joined.contains("iptables -t nat -D POSTROUTING \"$n\""))
        #expect(joined.contains("vpn-chain-exit.service"))
        #expect(joined.contains("--dport 51828"))
    }

    @Test func exitCommandsWithoutClientSubnet() {
        let commands = UninstallPlan.exitCommands(dockerSubnet: "172.26.0.0/16", clientSubnet: nil)
        let joined = commands.map { $0.command }.joined(separator: "\n")
        #expect(joined.contains("'172.26.0.0/16'"))
        #expect(!joined.contains("10.8.1.0/24"))
    }

    @Test func softwareRemovalIsSeparateAndExplicit() {
        let joined = UninstallPlan.optionalSoftwareRemoval.map { $0.command }.joined(separator: "\n")
        #expect(joined.contains("/usr/bin/awg"))
        #expect(joined.contains("/usr/bin/amneziawg-go"))
        #expect(joined.contains("/tmp/amneziawg-tools"))
        // Не входит в основной план.
        let main = joinedCommands()
        #expect(!main.contains("/usr/bin/awg"))
    }
}
