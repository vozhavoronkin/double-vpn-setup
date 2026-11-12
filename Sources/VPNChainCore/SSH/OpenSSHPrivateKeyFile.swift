import Crypto
import Foundation
import NIOSSH

/// Парсер приватных ключей OpenSSH (`openssh-key-v1`).
///
/// Поддерживает:
/// - `ssh-ed25519`, `ecdsa-sha2-nistp256/384/521` — алгоритмы, поддерживаемые NIOSSH;
/// - зашифрованные ключи (KDF `bcrypt`, cipher `aes256-ctr`/`aes256-cbc`) — расшифровка
///   делегируется системному `/usr/bin/ssh-keygen` (бойко проверенная реализация bcrypt-KDF),
///   расшифрованная копия живёт только во временном файле с правами 0600 и удаляется сразу.
/// RSA не поддерживается NIOSSH — даётся понятная ошибка (design.md, риск R1).
public enum OpenSSHPrivateKeyFile {
    public static func load(from pemData: Data, passphrase: String?) throws -> SSHKeyMaterial {
        let armor = String(decoding: pemData, as: UTF8.self)
        guard armor.contains("-----BEGIN OPENSSH PRIVATE KEY-----") else {
            if armor.contains("-----BEGIN") {
                // Старый PEM-формат (например, RSA PKCS#1) — не openssh-key-v1.
                throw SSHError.unsupportedKey(
                    "Формат ключа не поддерживается. Поддерживаются ключи OpenSSH (ssh-keygen -t ed25519 / ecdsa)."
                )
            }
            throw SSHError.keyParsing("Файл не похож на приватный ключ OpenSSH")
        }

        let (cipherName, body) = try parseEnvelope(armor: armor)

        if cipherName == "none" {
            return try parsePlain(body: body)
        }

        // Зашифрованный ключ: снимаем passphrase через системный ssh-keygen.
        guard let passphrase, !passphrase.isEmpty else {
            throw SSHError.keyParsing("Ключ зашифрован: требуется парольная фраза")
        }
        let plainData = try stripPassphrase(pemData: pemData, passphrase: passphrase)
        let (plainCipher, plainBody) = try parseEnvelope(
            armor: String(decoding: plainData, as: UTF8.self))
        guard plainCipher == "none" else {
            throw SSHError.keyParsing(
                "Не удалось снять парольную фразу с ключа (cipher=\(plainCipher))")
        }
        return try parsePlain(body: plainBody)
    }

    // MARK: - Конверт openssh-key-v1

    /// Возвращает имя cipher и расшифрованное тело приватной части.
    private static func parseEnvelope(armor: String) throws -> (cipher: String, body: [UInt8]) {
        let bodyLines =
            armor
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
        guard let bodyData = Data(base64Encoded: bodyLines.joined()) else {
            throw SSHError.keyParsing("Некорректный base64 в приватном ключе")
        }
        var bytes = [UInt8](bodyData)
        let magic = Array("openssh-key-v1\u{0}".utf8)
        guard bytes.starts(with: magic) else {
            throw SSHError.keyParsing("Нет магической последовательности openssh-key-v1")
        }
        bytes.removeFirst(magic.count)
        var reader = SSHWireReader(bytes: bytes)
        let cipher = try reader.readString()
        _ = try reader.readString()  // kdfname
        _ = try reader.readString()  // kdfoptions
        let numKeys = try reader.readUInt32()
        guard numKeys == 1 else {
            throw SSHError.keyParsing("Файл содержит \(numKeys) ключей, поддерживается один")
        }
        _ = try reader.readBytes()  // public key blob
        let privateSection = try reader.readBytes()
        return (cipher: cipher, body: privateSection)
    }

    /// Wire-строка SSH: uint32 длины (big-endian) + байты.
    static func sshString(_ bytes: [UInt8]) -> [UInt8] {
        let length = UInt32(bytes.count)
        return [
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ] + bytes
    }

    /// Разбор расшифрованной приватной части: checkints + один ключ.
    private static func parsePlain(body: [UInt8]) throws -> SSHKeyMaterial {
        var reader = SSHWireReader(bytes: body)
        let check1 = try reader.readUInt32()
        let check2 = try reader.readUInt32()
        guard check1 == check2 else {
            throw SSHError.wrongPassphrase
        }
        let algorithm = try reader.readString()
        switch algorithm {
        case "ssh-ed25519":
            let publicBlob = try reader.readBytes()
            let privateBlob = try reader.readBytes()
            guard privateBlob.count == 64 else {
                throw SSHError.keyParsing(
                    "Некорректная длина приватного ключа ed25519: \(privateBlob.count)")
            }
            let seed = Array(privateBlob[..<32])
            let key: Curve25519.Signing.PrivateKey
            do {
                key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            } catch {
                throw SSHError.keyParsing("Некорректный seed ed25519")
            }
            // Целостность: публичная часть внутри приватного блока должна совпадать с derived.
            guard Array(key.publicKey.rawRepresentation) == Array(publicBlob.suffix(32)) else {
                throw SSHError.keyParsing("Публичная часть ключа не соответствует приватной")
            }
            let comment = try? reader.readString()
            let pubKeyBytes = Array(key.publicKey.rawRepresentation)
            let blob = Self.sshString(Array("ssh-ed25519".utf8)) + Self.sshString(pubKeyBytes)
            let line = "ssh-ed25519 \(Data(blob).base64EncodedString())"
            return SSHKeyMaterial(
                algorithm: algorithm,
                comment: comment,
                publicKeyOpenSSH: line,
                privateKey: NIOSSHPrivateKey(ed25519Key: key)
            )
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let key: NIOSSHPrivateKey = try parseECDSA(algorithm: algorithm, reader: &reader)
            let comment = try? reader.readString()
            return SSHKeyMaterial(
                algorithm: algorithm,
                comment: comment,
                publicKeyOpenSSH: nil,
                privateKey: key
            )
        case "ssh-rsa":
            throw SSHError.unsupportedKey(
                "RSA-ключи не поддерживаются. Используйте ed25519/ecdsa-ключ или аутентификацию по паролю."
            )
        default:
            throw SSHError.unsupportedKey("Неизвестный тип ключа: \(algorithm)")
        }
    }

    private static func parseECDSA(algorithm: String, reader: inout SSHWireReader) throws
        -> NIOSSHPrivateKey
    {
        _ = try reader.readString()  // имя кривой
        _ = try reader.readBytes()  // публичная точка
        var scalar = try reader.readBytes()
        switch algorithm {
        case "ecdsa-sha2-nistp256":
            padLeft(&scalar, to: 32)
            let key = try P256.Signing.PrivateKey(rawRepresentation: Data(scalar))
            return NIOSSHPrivateKey(p256Key: key)
        case "ecdsa-sha2-nistp384":
            padLeft(&scalar, to: 48)
            let key = try P384.Signing.PrivateKey(rawRepresentation: Data(scalar))
            return NIOSSHPrivateKey(p384Key: key)
        default:
            padLeft(&scalar, to: 66)
            let key = try P521.Signing.PrivateKey(rawRepresentation: Data(scalar))
            return NIOSSHPrivateKey(p521Key: key)
        }
    }

    private static func padLeft(_ bytes: inout [UInt8], to size: Int) {
        while bytes.count < size { bytes.insert(0, at: 0) }
        if bytes.count > size { bytes = Array(bytes.suffix(size)) }
    }

    // MARK: - Снятие passphrase через ssh-keygen

    private static func stripPassphrase(pemData: Data, passphrase: String) throws -> Data {
        let fm = FileManager.default
        let tmpPath = fm.temporaryDirectory
            .appendingPathComponent("vpnchain-key-\(UUID().uuidString)").path
        let cleanup = { try? fm.removeItem(atPath: tmpPath) }
        defer { cleanup() }

        try pemData.write(to: URL(fileURLWithPath: tmpPath))
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        // Парольная фраза передаётся аргументом: однопользовательская рабочая станция,
        // процесс живёт доли секунды; альтернатива — собственная реализация bcrypt-KDF.
        process.arguments = ["-p", "-P", passphrase, "-N", "", "-q", "-f", tmpPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw SSHError.keyParsing("ssh-keygen недоступен: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SSHError.wrongPassphrase
        }
        return try Data(contentsOf: URL(fileURLWithPath: tmpPath))
    }
}

/// Чтец wire-формата SSH (uint32/big-endian + length-prefixed строки).
struct SSHWireReader {
    private var bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readUInt32() throws -> UInt32 {
        guard bytes.count >= offset + 4 else {
            throw SSHError.keyParsing("Обрыв данных wire-формата")
        }
        let value =
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    mutating func readBytes() throws -> [UInt8] {
        let length = Int(try readUInt32())
        guard bytes.count >= offset + length else {
            throw SSHError.keyParsing("Обрыв данных wire-формата")
        }
        let slice = Array(bytes[offset..<(offset + length)])
        offset += length
        return slice
    }

    mutating func readString() throws -> String {
        String(decoding: try readBytes(), as: UTF8.self)
    }
}
