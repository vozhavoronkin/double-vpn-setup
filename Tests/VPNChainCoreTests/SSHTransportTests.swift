import Crypto
import Foundation
import NIOSSH
import Testing
@testable import VPNChainCore

/// Unit-тесты SSH-транспорта задачи 2.1: буферизация вывода, таймауты,
/// коллектор результата, парсер OpenSSH-ключей (включая passphrase и RSA-reject).
struct SSHTransportTests {
    // MARK: ChunkAssembler — буферизация вывода

    @Test func assemblerMergesSplitsAcrossChunks() {
        let assembler = ChunkAssembler()
        let first = assembler.append(Array("hello ".utf8))
        let second = assembler.append(Array("world".utf8))
        #expect(first == "hello ")
        #expect(second == "world")
        #expect(assembler.finalize().isEmpty)
    }

    @Test func assemblerDoesNotSplitMultibyteCharacters() {
        let full = Array("привет".utf8) // каждый символ 2 байта
        let assembler = ChunkAssembler()
        let first = assembler.append(Array(full[..<1])) // разрез посреди первого символа
        #expect(first.isEmpty)
        let rest = assembler.append(Array(full[1...]))
        #expect(rest == "привет")
        #expect(!assembler.hasPendingBytes)
    }

    @Test func assemblerHandlesEmojiSplits() {
        let full = "ok 🛡 done"
        let bytes = Array(full.utf8) // emoji 🛡 — 4 байта
        let assembler = ChunkAssembler()
        // Разрез внутри emoji: "ok " (3 байта) + первый байт emoji.
        let first = assembler.append(Array(bytes[..<4]))
        let rest = assembler.append(Array(bytes[4...]))
        #expect(first == "ok ")
        #expect(first + rest == full)
    }

    @Test func assemblerFinalizeFlushesBrokenTail() {
        let assembler = ChunkAssembler()
        _ = assembler.append([0xF0, 0x9F]) // оборванная 4-байтовая последовательность
        #expect(assembler.hasPendingBytes)
        #expect(!assembler.finalize().isEmpty)
        #expect(!assembler.hasPendingBytes)
    }

    // MARK: ExecCollector — накопление результата

    @Test func collectorAggregatesStreamsAndExitCode() {
        let collector = ExecCollector()
        collector.markOpened()
        collector.appendStdout(Array("line1\n".utf8))
        collector.appendStderr(Array("warn\n".utf8))
        collector.appendStdout(Array("line2\n".utf8))
        collector.markExitStatus(3)
        collector.markEOF()
        collector.markInactive()
        let result = collector.snapshotResult()
        #expect(result.exitCode == 3)
        #expect(result.stdout == "line1\nline2\n")
        #expect(result.stderr == "warn\n")
        #expect(result.succeeded == false)
    }

    @Test func collectorSuccessResult() {
        let collector = ExecCollector()
        collector.markOpened()
        collector.appendStdout(Array("ok".utf8))
        collector.markExitStatus(0)
        collector.markInactive()
        let result = collector.snapshotResult()
        #expect(result.succeeded == true)
    }

    // MARK: Таймаут-логика

    @Test func timeoutFiresForSlowOperation() async throws {
        try await confirmation("onTimeout вызван") { confirmed in
            do {
                _ = try await SSHClient.withTimeout(
                    seconds: 0.15,
                    onTimeout: { confirmed() }
                ) {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    return 1
                }
                Issue.record("Операция должна была упасть по таймауту")
            } catch let error as SSHError {
                guard case .timeout = error else {
                    Issue.record("Ожидался SSHError.timeout, получено: \(error)")
                    return
                }
            }
        }
    }

    @Test func fastOperationSurvivesTimeoutRace() async throws {
        let result = try await SSHClient.withTimeout(
            seconds: 2.0,
            onTimeout: {}
        ) {
            return 42
        }
        #expect(result == 42)
    }

    // MARK: Отпечаток host key

    /// Wire-строка SSH (uint32 длины + байты) — для сборки OpenSSH-строки ключа в тестах.
    private func sshString(_ bytes: [UInt8]) -> [UInt8] {
        let length = UInt32(bytes.count)
        return [
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ] + bytes
    }

    @Test func fingerprintIsOpenSSHStyle() throws {
        let key = Curve25519.Signing.PrivateKey()
        let blob = sshString(Array("ssh-ed25519".utf8)) + sshString(Array(key.publicKey.rawRepresentation))
        let openSSH = "ssh-ed25519 \(Data(blob).base64EncodedString())"
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: openSSH)
        let fingerprint = SSHClient.fingerprint(of: publicKey)
        #expect(fingerprint.hasPrefix("SHA256:"))
        #expect(!fingerprint.contains("="))
    }

    // MARK: OpenSSHPrivateKeyFile — парсер приватных ключей

    /// Генерирует реальную пару ключей системным ssh-keygen.
    private func generateKey(
        type: String,
        bits: Int? = nil,
        passphrase: String?,
        comment: String = "vpnchain-test"
    ) throws -> (privateKeyData: Data, publicKeyLine: String, path: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpnchain-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let privatePath = directory.appendingPathComponent("id_\(type)").path
        var arguments = ["-t", type, "-N", passphrase ?? "", "-C", comment, "-q", "-f", privatePath]
        if let bits {
            arguments.insert(contentsOf: ["-b", String(bits)], at: 2)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SSHError.keyParsing("ssh-keygen сгенерировал ошибку для \(type)")
        }
        let privateData = try Data(contentsOf: URL(fileURLWithPath: privatePath))
        let publicLine = try String(contentsOf: URL(fileURLWithPath: privatePath + ".pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        defer { try? FileManager.default.removeItem(at: directory) }
        return (privateData, publicLine, URL(fileURLWithPath: privatePath))
    }

    private func publicKeyTokens(_ line: String) -> String {
        line.split(separator: " ").prefix(2).joined(separator: " ")
    }

    @Test func parsesUnencryptedEd25519Key() throws {
        let generated = try generateKey(type: "ed25519", passphrase: nil)
        let material = try OpenSSHPrivateKeyFile.load(from: generated.privateKeyData, passphrase: nil)
        #expect(material.algorithm == "ssh-ed25519")
        #expect(
            material.publicKeyOpenSSH == publicKeyTokens(generated.publicKeyLine),
            "actual: \(material.publicKeyOpenSSH ?? "nil"), expected: \(publicKeyTokens(generated.publicKeyLine))"
        )
    }

    @Test func parsesEncryptedEd25519KeyWithPassphrase() throws {
        let generated = try generateKey(type: "ed25519", passphrase: "секрет-123")
        let material = try OpenSSHPrivateKeyFile.load(from: generated.privateKeyData, passphrase: "секрет-123")
        #expect(material.algorithm == "ssh-ed25519")
        #expect(material.publicKeyOpenSSH == publicKeyTokens(generated.publicKeyLine))
    }

    @Test func encryptedKeyWithoutPassphraseFails() throws {
        let generated = try generateKey(type: "ed25519", passphrase: "секрет-123")
        #expect(throws: SSHError.keyParsing("Ключ зашифрован: требуется парольная фраза")) {
            try OpenSSHPrivateKeyFile.load(from: generated.privateKeyData, passphrase: nil)
        }
    }

    @Test func encryptedKeyWithWrongPassphraseFails() throws {
        let generated = try generateKey(type: "ed25519", passphrase: "секрет-123")
        #expect(throws: SSHError.wrongPassphrase) {
            try OpenSSHPrivateKeyFile.load(from: generated.privateKeyData, passphrase: "неверный")
        }
    }

    @Test func rsaKeyIsRejectedWithClearError() throws {
        let generated = try generateKey(type: "rsa", bits: 2048, passphrase: nil)
        do {
            _ = try OpenSSHPrivateKeyFile.load(from: generated.privateKeyData, passphrase: nil)
            Issue.record("RSA-ключ должен был быть отклонён")
        } catch let error as SSHError {
            guard case .unsupportedKey = error else {
                Issue.record("Ожидался SSHError.unsupportedKey, получено: \(error)")
                return
            }
        }
    }

    @Test func garbageInputIsRejected() {
        #expect(throws: SSHError.keyParsing("Файл не похож на приватный ключ OpenSSH")) {
            try OpenSSHPrivateKeyFile.load(from: Data("not a key".utf8), passphrase: nil)
        }
    }
}
