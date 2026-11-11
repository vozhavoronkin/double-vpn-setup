import Crypto
import Foundation

/// Пара ключей WireGuard для relay-участка (base64, формат `awg genkey`/`awg pubkey`).
public struct WireGuardKeyPair: Sendable, Equatable, Codable {
    /// Имя узла, например `s1-relay`.
    public let name: String
    /// Приватный ключ в base64 (32 байта с клампингом).
    public let privateKey: String
    /// Публичный ключ в base64 (производный от приватного).
    public let publicKey: String

    public init(name: String, privateKey: String, publicKey: String) {
        self.name = name
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

/// Генерация ключей WireGuard на Mac (CryptoKit X25519), по правилам `awg genkey`:
/// приватный ключ — 32 байта с клампингом (raw[0] &= 248; raw[31] &= 127; raw[31] |= 64).
public enum WireGuardKeys {
    /// Генерирует пару ключей.
    public static func generateKeyPair(name: String) throws -> WireGuardKeyPair {
        var random = Array(Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        clamp(&random)
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(random))
        let publicKey = privateKey.publicKey.rawRepresentation
        return WireGuardKeyPair(
            name: name,
            privateKey: Data(random).base64EncodedString(),
            publicKey: Data(publicKey).base64EncodedString()
        )
    }

    /// Клампинг байтов приватного ключа по правилам WireGuard.
    public static func clamp(_ bytes: inout [UInt8]) {
        guard bytes.count == 32 else { return }
        bytes[0] &= 248
        bytes[31] &= 127
        bytes[31] |= 64
    }

    /// Восстанавливает пару из сохранённого приватного ключа (base64) — для идемпотентности.
    public static func keyPair(name: String, privateKeyBase64: String) throws -> WireGuardKeyPair {
        guard let data = Data(base64Encoded: privateKeyBase64), data.count == 32 else {
            throw SecretError.invalidKeyFormat("приватный ключ \(name): не base64 длиной 32 байта")
        }
        var raw = [UInt8](data)
        clamp(&raw)
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(raw))
        return WireGuardKeyPair(
            name: name,
            privateKey: Data(raw).base64EncodedString(),
            publicKey: Data(privateKey.publicKey.rawRepresentation).base64EncodedString()
        )
    }

    /// Проверка формата приватного ключа (base64, 32 байта).
    public static func isValidPrivateKey(_ base64: String) -> Bool {
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return false }
        return true
    }
}

/// Ошибки работы с секретами.
public enum SecretError: Error, Equatable {
    case invalidKeyFormat(String)
    case invalidParams(String)
}
