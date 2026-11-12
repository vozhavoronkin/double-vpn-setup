import Foundation
import Testing

@testable import VPNChainCore

/// Тесты задач 5.1–5.3: рендеры конфигурации С2/С1 и правил.
struct ConfigureStepsTests {
    private let obf = ObfuscationParams(
        jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 9, h2: 10, h3: 11, h4: 12)

    // MARK: 5.1 — правила выхода С2

    @Test func c2RulesScriptIsIdempotentAndMarked() {
        let script = ConfigureC2.renderRulesScript(
            wanInterface: "eth0",
            dockerSubnet: "172.26.0.0/16",
            clientSubnet: "10.8.1.0/24"
        )
        // Идемпотентность: guard-проверки -C перед добавлением.
        #expect(script.contains("iptables -C INPUT -p udp --dport 51828 -j ACCEPT 2>/dev/null ||"))
        #expect(
            script.contains(
                "iptables -t nat -C POSTROUTING -s \"$DOCKER_SUBNET\" -o \"$WAN\" -j MASQUERADE 2>/dev/null ||"
            ))
        // Клиентская подсеть покрывается MASQUERADE.
        #expect(script.contains("-s '10.8.1.0/24' -o \"$WAN\" -j MASQUERADE"))
        // Регрессия приёмки: трафик из туннеля (после SNAT Docker'а на С1) тоже NAT-ится.
        #expect(script.contains("-s 10.99.0.0/24 -o \"$WAN\" -j MASQUERADE"))
        // ip_forward с персистентностью и .bak.
        #expect(script.contains("net.ipv4.ip_forward = 1"))
        #expect(script.contains(".bak.$(date +%s)"))
        #expect(script.contains("# managed-by: amnezia-chain"))
        #expect(script.contains("WAN='eth0'"))
        // SSH не блокируется.
        #expect(!script.contains("iptables -P INPUT DROP"))
    }

    @Test func c2RulesScriptWithoutClientSubnet() {
        let script = ConfigureC2.renderRulesScript(
            wanInterface: "ens3", dockerSubnet: "172.26.0.0/16", clientSubnet: nil)
        #expect(script.contains("клиентская подсеть не обнаружена"))
        #expect(!script.contains("-s '10.8.1.0/24'"))
    }

    @Test func c2WANParsing() {
        #expect(
            ConfigureC2.parseDefaultInterface("default via 10.0.0.1 dev eth0 proto dhcp metric 100")
                == "eth0")
        #expect(ConfigureC2.parseDefaultInterface("default dev ens3") == "ens3")
        #expect(ConfigureC2.parseDefaultInterface("") == nil)
    }

    @Test func c2ActionsCoverConfigRelayAndRules() {
        let config = ConfigTemplates.renderC2(
            obf: obf,
            s2PrivateKey: "PRIV2",
            s1RelayPublicKey: "S1PUB",
            dockerSubnet: "172.26.0.0/16",
            clientSubnet: nil
        )
        let actions = ConfigureC2.actions(
            configContent: config, wanInterface: "eth0", dockerSubnet: "172.26.0.0/16",
            clientSubnet: nil)
        #expect(
            actions.map { $0.id } == [
                "c2-config", "c2-preclean", "c2-subnet-collision", "c2-enable-relay", "c2-rules",
            ])
        // Relay включается отдельным действием.
        #expect(actions[3].apply == SystemdUnits.enableRelayCommand())
        let rules = actions[4].apply
        #expect(actions[0].apply.contains("chmod 0600 '/etc/amnezia/amneziawg/awg-relay.conf'"))
        // Приватный ключ доставляется в конфиг (регрессия приёмки: интерфейсы без ключей).
        #expect(actions[0].apply.contains("PrivateKey = PRIV2"))
        #expect(rules.contains("systemctl restart vpn-chain-exit.service"))
        // Юнит персистентности с маркером.
        #expect(rules.contains("vpn-chain-exit.service"))
        #expect(rules.contains("managed-by: amnezia-chain"))
        // Конфиг С2 без 0.0.0.0/0.
        #expect(!actions[0].apply.contains("AllowedIPs = 0.0.0.0/0"))
    }

    @Test func c2PreCleanRemovesOnlyOurLeftovers() {
        let preclean = ConfigureC2.preCleanCommand(
            dockerSubnet: "172.26.0.0/16", clientSubnet: "10.8.1.0/24")
        // Интерфейс и только наши маршруты (dev awg-relay).
        #expect(preclean.contains("ip link del awg-relay type amneziawg"))
        #expect(preclean.contains("ip route del '172.26.0.0/16' dev awg-relay"))
        #expect(preclean.contains("ip route del '10.99.0.0/24' dev awg-relay"))
        #expect(preclean.contains("ip route del '10.8.1.0/24' dev awg-relay"))
        // Чужие сети не трогаем: нет удаления без dev-фильтра.
        #expect(!preclean.contains("ip route del '172.26.0.0/16' 2>/dev/null"))
    }

    @Test func c2CollisionCheckFailsWithClearMessage() {
        let script = ConfigureC2.collisionCheckCommand(dockerSubnet: "172.26.0.0/16")
        #expect(script.contains("grep -F '172.26.0.0/16'"))
        #expect(script.contains("grep -vF 'dev awg-relay'"))
        #expect(script.contains("exit 1"))
        #expect(script.contains("КОЛЛИЗИЯ ПОДСЕТЕЙ"))
    }

    // MARK: 5.2 — конфигурация С1

    @Test func c1ConfigActionsInOrder() {
        let config = ConfigTemplates.renderC1(
            obf: obf, s1PrivateKey: "PRIV1", s2RelayPublicKey: "S2PUB", s2IP: "203.0.113.9")
        let actions = ConfigureC1.actions(
            configContent: config, bridge: "br-9f7e5c1a2b3d", clientPort: "44949")
        #expect(
            actions.map { $0.id } == [
                "c1-config", "c1-awgquick-unit", "c1-enable-relay", "c1-rules",
            ])
        #expect(
            actions[1].apply.contains("if [ ! -f /etc/systemd/system/awg-quick@.service ]; then"))
        #expect(actions[3].apply.contains("systemctl restart vpn-chain.service"))
    }

    // MARK: 5.3 — vpn-chain-rules.sh

    @Test func c1RulesScriptContainsAllRules() {
        let script = ConfigureC1.renderRulesScript(bridge: "br-9f7e5c1a2b3d", clientPort: "44949")
        // Отбор трафика — по метке, а НЕ по интерфейсу (регрессия: iif ломал клиента).
        #expect(script.contains("ip rule add fwmark \"$MARK\" table 51821 priority 100"))
        #expect(!script.contains("ip rule add iif"))
        // Ответы контейнера клиентам исключены из туннеля (handshake клиента).
        #expect(
            script.contains(
                "iptables -t mangle -A VPNCHAIN_MARK -i \"$BRIDGE\" -p udp --sport \"$CLIENT_PORT\" -j RETURN"
            ))
        #expect(
            script.contains(
                "iptables -t mangle -A VPNCHAIN_MARK -i \"$BRIDGE\" -j MARK --set-mark \"$MARK\""))
        #expect(
            script.contains(
                "ip6tables -A VPNCHAIN6 -i \"$BRIDGE\" -p udp --sport \"$CLIENT_PORT\" -j RETURN"))
        // Регрессия приёмки: Docker SNAT клиентского трафика не должен портить источник
        // при уходе в туннель (иначе интернет не отвечает).
        #expect(script.contains("iptables -t nat -I POSTROUTING 1 -o awg-relay -j RETURN"))
        #expect(script.contains("ip route replace default dev awg-relay table 51821"))
        #expect(script.contains("ip route replace blackhole default table 51821 metric 42760"))
        // rp_filter на интерфейсе + default в persist (исправление к ТЗ).
        #expect(script.contains("sysctl -w net.ipv4.conf.awg-relay.rp_filter=2"))
        #expect(script.contains("net.ipv4.conf.default.rp_filter = 2"))
        // Цепочки в DOCKER-USER с fallback.
        #expect(script.contains("BASE_CHAIN=DOCKER-USER"))
        #expect(script.contains("DOCKER-USER не найдена, правила добавляются в FORWARD"))
        #expect(
            script.contains(
                "iptables -C \"$BASE_CHAIN\" -j VPNCHAIN 2>/dev/null || iptables -I \"$BASE_CHAIN\" 1 -j VPNCHAIN"
            ))
        #expect(script.contains("ip6tables -A VPNCHAIN6 -i \"$BRIDGE\" -j DROP"))
        // MSS clamp и возврат трафика.
        #expect(script.contains("--clamp-mss-to-pmtu"))
        #expect(script.contains("conntrack --ctstate RELATED,ESTABLISHED"))
        // .bak перед перезаписью persist-файла.
        #expect(script.contains(".bak.$(date +%s)"))
        #expect(script.contains("# managed-by: amnezia-chain"))
    }

    @Test func c1RulesScriptIdempotent() {
        let script = ConfigureC1.renderRulesScript(bridge: "br-x", clientPort: "44949")
        // Снятие всех прежних правил нашей таблицы перед add; -C перед -I/-F для цепочек.
        #expect(script.contains("while ip rule del table 51821 2>/dev/null; do :; done"))
        #expect(script.contains("iptables -N VPNCHAIN 2>/dev/null || true"))
        #expect(script.contains("iptables -F VPNCHAIN"))
    }
}
