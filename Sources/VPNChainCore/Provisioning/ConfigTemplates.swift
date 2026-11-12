import Foundation

/// Рендер конфигов `awg-relay` по шаблонам ТЗ 9.1 (С1) и 9.2 (С2)
/// и команда доставки файла на сервер (с правами 0600 и каталогом 0700).
public enum ConfigTemplates {
    /// Шаблон 9.1 — Сервер 1 (вход).
    public static func renderC1(
        obf: ObfuscationParams,
        s1PrivateKey: String,
        s2RelayPublicKey: String,
        s2IP: String
    ) -> String {
        """
        [Interface]
        PrivateKey = \(s1PrivateKey)
        Address = 10.99.0.1/24
        Table = off
        MTU = 1420
        \(obfLines(obf))
        # ListenPort не задаём: С1 инициирует соединение сам

        [Peer]
        # Сервер 2 (выход)
        PublicKey = \(s2RelayPublicKey)
        Endpoint = \(s2IP):51828
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25
        """
    }

    /// Шаблон 9.2 — Сервер 2 (выход). AllowedIPs только внутренние подсети,
    /// никогда 0.0.0.0/0 — иначе С2 завернёт собственный SSH-трафик в туннель.
    public static func renderC2(
        obf: ObfuscationParams,
        s2PrivateKey: String,
        s1RelayPublicKey: String,
        dockerSubnet: String,
        clientSubnet: String?
    ) -> String {
        let allowedIPs: String
        if let clientSubnet, !clientSubnet.isEmpty {
            allowedIPs = "AllowedIPs = 10.99.0.0/24, \(dockerSubnet), \(clientSubnet)"
        } else {
            allowedIPs = "AllowedIPs = 10.99.0.0/24, \(dockerSubnet)"
        }
        return """
            [Interface]
            PrivateKey = \(s2PrivateKey)
            Address = 10.99.0.2/24
            ListenPort = 51828
            MTU = 1420
            \(obfLines(obf))

            [Peer]
            # Сервер 1 (вход): принимает расшифрованный клиентский трафик
            PublicKey = \(s1RelayPublicKey)
            \(allowedIPs)
            """
    }

    private static func obfLines(_ obf: ObfuscationParams) -> String {
        obf.ordered.map { "\($0.name) = \($0.value)" }.joined(separator: "\n")
    }
}

/// Команда доставки файла на сервер: создаёт каталог с правами 0700, делает
/// резервную копию `.bak.<timestamp>` перед перезаписью (ТЗ раздел 5), пишет
/// содержимое через heredoc и выставляет права файла (по умолчанию 0600).
/// Контент снабжается маркером `# managed-by: amnezia-chain`.
///
/// Разделитель heredoc генерируется случайным и уникальным для каждой доставки:
/// содержимое может само содержать вложенные heredoc'и (например, скрипт правил
/// пишет persist-файл через `<<'VPNCHAIN_EOF'`) — фиксированный разделитель
/// закрывался бы вложенной строкой и обрезал файл на середине.
public enum FileDelivery {
    public static func command(
        path: String, content: String, mode: String = "0600", backup: Bool = true
    ) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let delimiter = uniqueDelimiter(for: content)
        var lines = [
            "mkdir -p -m 0700 '\(directory)'"
        ]
        if backup {
            lines.append("if [ -f '\(path)' ]; then cp -f '\(path)' '\(path).bak.$(date +%s)'; fi")
        }
        lines.append(contentsOf: [
            "cat > '\(path)' <<'\(delimiter)'",
            markedContent(content),
            delimiter,
            "chmod \(mode) '\(path)'",
        ])
        return lines.joined(separator: "\n")
    }

    /// Контент с маркером. Если содержимое начинается с шебанга, маркер встаёт
    /// ПОСЛЕ него: `#!/…` обязан остаться первой строкой файла, иначе systemd
    /// не сможет исполнить скрипт (ExecStart, ENOEXEC).
    static func markedContent(_ content: String) -> String {
        let marker = "# managed-by: amnezia-chain"
        guard content.hasPrefix("#!") else {
            return marker + "\n" + content
        }
        guard let firstLineEnd = content.firstIndex(of: "\n") else {
            return content + "\n" + marker
        }
        let firstLine = String(content[..<firstLineEnd])
        let rest = String(content[content.index(after: firstLineEnd)...])
        return firstLine + "\n" + marker + "\n" + rest
    }

    /// Случайный разделитель, отсутствующий в содержимом.
    static func uniqueDelimiter(for content: String) -> String {
        var delimiter = ""
        repeat {
            let hex = UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(12)
                .lowercased()
            delimiter = "VPNCHAIN_EOF_\(hex)"
        } while content.contains(delimiter)
        return delimiter
    }
}
