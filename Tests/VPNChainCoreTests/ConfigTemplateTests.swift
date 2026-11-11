import Foundation
import Testing
@testable import VPNChainCore

/// Тесты задачи 3.4: рендер конфигов 9.1/9.2 и команды доставки файлов.
struct ConfigTemplateTests {
    private let obf = ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 9, h2: 10, h3: 11, h4: 12)

    @Test func c1ConfigMatchesTemplate9_1() {
        let config = ConfigTemplates.renderC1(obf: obf, s1PrivateKey: "PRIV1", s2RelayPublicKey: "S2PUB", s2IP: "203.0.113.2")
        #expect(config.contains("PrivateKey = PRIV1"))
        #expect(config.contains("Address = 10.99.0.1/24"))
        #expect(config.contains("Table = off"))
        #expect(config.contains("MTU = 1420"))
        #expect(!config.contains("ListenPort =")) // присваивания ListenPort у С1 нет (комментарий ТЗ допустим)
        #expect(config.contains("PublicKey = S2PUB"))
        #expect(config.contains("Endpoint = 203.0.113.2:51828"))
        #expect(config.contains("AllowedIPs = 0.0.0.0/0"))
        #expect(config.contains("PersistentKeepalive = 25"))
    }

    @Test func c2ConfigMatchesTemplate9_2() {
        let config = ConfigTemplates.renderC2(
            obf: obf,
            s2PrivateKey: "PRIV2",
            s1RelayPublicKey: "S1PUB",
            dockerSubnet: "172.26.0.0/16",
            clientSubnet: "10.8.1.0/24"
        )
        #expect(config.contains("PrivateKey = PRIV2"))
        #expect(config.contains("Address = 10.99.0.2/24"))
        #expect(config.contains("ListenPort = 51828"))
        #expect(config.contains("MTU = 1420"))
        #expect(config.contains("PublicKey = S1PUB"))
        #expect(config.contains("AllowedIPs = 10.99.0.0/24, 172.26.0.0/16, 10.8.1.0/24"))
        // На С2 никогда не бывает 0.0.0.0/0
        #expect(!config.contains("0.0.0.0/0"))
    }

    @Test func c2ConfigWithoutClientSubnet() {
        let config = ConfigTemplates.renderC2(
            obf: obf,
            s2PrivateKey: "PRIV2",
            s1RelayPublicKey: "S1PUB",
            dockerSubnet: "172.26.0.0/16",
            clientSubnet: nil
        )
        #expect(config.contains("AllowedIPs = 10.99.0.0/24, 172.26.0.0/16"))
        #expect(!config.contains("10.8.1.0/24"))
    }

    @Test func obfuscationParamsIdenticalOnBothEnds() {
        let c1 = ConfigTemplates.renderC1(obf: obf, s1PrivateKey: "PRIV1", s2RelayPublicKey: "S2PUB", s2IP: "203.0.113.2")
        let c2 = ConfigTemplates.renderC2(
            obf: obf,
            s2PrivateKey: "PRIV2",
            s1RelayPublicKey: "S1PUB",
            dockerSubnet: "172.26.0.0/16",
            clientSubnet: nil
        )
        for param in obf.ordered {
            let line = "\(param.name) = \(param.value)"
            #expect(c1.contains(line), "С1 не содержит \(line)")
            #expect(c2.contains(line), "С2 не содержит \(line)")
        }
    }

    @Test func fileDeliverySetsPermissionsAndMarker() {
        let content = "[Interface]\nAddress = 10.99.0.1/24\n"
        let command = FileDelivery.command(path: "/etc/amnezia/amneziawg/awg-relay.conf", content: content)
        #expect(command.contains("mkdir -p -m 0700 '/etc/amnezia/amneziawg'"))
        #expect(command.contains("chmod 0600 '/etc/amnezia/amneziawg/awg-relay.conf'"))
        #expect(command.contains("<<'VPNCHAIN_EOF_"))
        #expect(command.contains("# managed-by: amnezia-chain"))
        #expect(command.contains(content))
    }

    /// Шебанг обязан остаться первой строкой файла (иначе systemd не исполнит скрипт).
    @Test func shebangStaysFirstLine() {
        let script = "#!/usr/bin/env bash\nset -Eeuo pipefail\necho ok\n"
        let command = FileDelivery.command(path: "/usr/local/bin/x.sh", content: script, mode: "0755")
        let lines = command.components(separatedBy: "\n")
        guard let catIndex = lines.firstIndex(where: { $0.contains("cat > '/usr/local/bin/x.sh'") }) else {
            Issue.record("Нет cat-строки")
            return
        }
        #expect(lines[catIndex + 1].hasPrefix("#!/usr/bin/env bash"))
        #expect(lines[catIndex + 2] == "# managed-by: amnezia-chain")

        // Обычный файл — маркер первой строкой контента.
        let plain = FileDelivery.command(path: "/etc/x.conf", content: "key = value", mode: "0600")
        let plainLines = plain.components(separatedBy: "\n")
        guard let plainCat = plainLines.firstIndex(where: { $0.contains("cat > '/etc/x.conf'") }) else {
            Issue.record("Нет cat-строки")
            return
        }
        #expect(plainLines[plainCat + 1] == "# managed-by: amnezia-chain")
    }

    /// Регрессия: содержимое с собственным heredoc-разделителем (скрипт правил
    /// пишет persist-файл через `<<'VPNCHAIN_EOF'`) должно доставляться целиком.
    @Test func deliverySurvivesContentWithInnerHeredoc() {
        let content = """
        #!/usr/bin/env bash
        set -Eeuo pipefail
        cat > /etc/sysctl.d/99-vpn-chain.conf <<'VPNCHAIN_EOF'
        net.ipv4.ip_forward = 1
        VPNCHAIN_EOF
        echo done
        """
        let command = FileDelivery.command(path: "/usr/local/bin/vpn-chain-exit-rules.sh", content: content, mode: "0755")
        let lines = command.components(separatedBy: "\n")

        // Разделитель не совпадает с вложенным и встречается ровно дважды (открытие/закрытие).
        let catLine = lines.first { $0.contains("cat > '/usr/local/bin/vpn-chain-exit-rules.sh'") } ?? ""
        guard let openRange = catLine.range(of: "<<'") else {
            Issue.record("Нет открывающего heredoc")
            return
        }
        let delimiter = String(catLine[openRange.upperBound...].dropLast(1)) // без закрывающей кавычки
        #expect(delimiter != "VPNCHAIN_EOF")
        // «Голая» строка-разделитель в команде ровно одна — закрывающая.
        let delimiterLines = lines.filter { $0 == delimiter }
        #expect(delimiterLines.count == 1)
        #expect(catLine.contains("<<'\(delimiter)'"))

        // Внутренний разделитель содержимого сохранён как данные.
        #expect(command.contains("<<'VPNCHAIN_EOF'"))
        #expect(command.contains("net.ipv4.ip_forward = 1"))

        // Закрытие идёт после последней строки содержимого, chmod — после закрытия.
        let closeIndex = lines.lastIndex { $0 == delimiter } ?? 0
        let contentEndIndex = lines.lastIndex { $0.contains("echo done") } ?? 0
        let chmodIndex = lines.lastIndex { $0.contains("chmod 0755") } ?? 0
        #expect(closeIndex > contentEndIndex)
        #expect(chmodIndex > closeIndex)
    }
}
