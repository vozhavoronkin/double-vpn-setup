import Foundation

/// Состояние установки на серверах: ключи, параметры обфускации, окружение С1.
/// Хранится в `/etc/amnezia/chain/` (каталог 0700, файлы 0600).
public struct ChainState: Sendable, Equatable {
    /// Окружение С1 из файла `env`.
    public struct Environment: Sendable, Equatable {
        public let bridge: String
        public let dockerSubnet: String
        public let containerIP: String
        /// Имя контейнера AmneziaWG (из детекта; для проверок `docker exec`).
        public let containerName: String?
        /// Клиентская подсеть AWG (мягкий детект, может отсутствовать).
        public let clientSubnet: String?
        /// Порт клиентского AWG (ListenPort в конфиге контейнера) — нужен, чтобы
        /// исключить ответы контейнера клиентам из relay-туннеля.
        public let clientPort: String?
        /// Commit сборки amneziawg-go (одинаковый на обоих серверах).
        public let commit: String?
        /// Commit сборки amneziawg-tools.
        public let commitTools: String?

        public init(
            bridge: String,
            dockerSubnet: String,
            containerIP: String,
            containerName: String? = nil,
            clientSubnet: String? = nil,
            clientPort: String? = nil,
            commit: String? = nil,
            commitTools: String? = nil
        ) {
            self.bridge = bridge
            self.dockerSubnet = dockerSubnet
            self.containerIP = containerIP
            self.containerName = containerName
            self.clientSubnet = clientSubnet
            self.clientPort = clientPort
            self.commit = commit
            self.commitTools = commitTools
        }
    }

    public let s1: WireGuardKeyPair
    public let s2: WireGuardKeyPair
    public let obf: ObfuscationParams
    public let environment: Environment

    public init(
        s1: WireGuardKeyPair, s2: WireGuardKeyPair, obf: ObfuscationParams, environment: Environment
    ) {
        self.s1 = s1
        self.s2 = s2
        self.obf = obf
        self.environment = environment
    }
}

/// Парсер и валидатор состояния `/etc/amnezia/chain/` (задача 3.3).
///
/// Перед переиспользованием найденного состояния проверяются: формат ключей,
/// совпадение публичных с производными от приватных, все правила раздела 4 ТЗ.
/// Невалидное состояние не используется молча — возвращается конкретная ошибка.
public enum ChainStateParser {
    public enum StateError: Error, Equatable {
        case missingFile(String)
        case invalidKeyFormat(String)
        case publicKeyMismatch(String)
        case invalidParams(String)
        case invalidEnvironment(String)
    }

    /// Файловая карта: имя файла → содержимое.
    /// Ожидаемые ключи: `s1-relay.key`, `s1-relay.pub`, `s2-relay.key`, `s2-relay.pub`,
    /// `obf.conf`, `env`.
    public static func parse(files: [String: String]) throws -> ChainState {
        for required in [
            "s1-relay.key", "s1-relay.pub", "s2-relay.key", "s2-relay.pub", "obf.conf", "env",
        ] {
            guard files[required] != nil else {
                throw StateError.missingFile(required)
            }
        }
        let s1 = try parseKeyPair(
            name: "s1-relay", privateKey: files["s1-relay.key"]!, publicKey: files["s1-relay.pub"]!)
        let s2 = try parseKeyPair(
            name: "s2-relay", privateKey: files["s2-relay.key"]!, publicKey: files["s2-relay.pub"]!)
        let obf = try parseObfuscation(files["obf.conf"]!)
        let environment = try parseEnvironment(files["env"]!)
        return ChainState(s1: s1, s2: s2, obf: obf, environment: environment)
    }

    // MARK: Ключи

    private static func trimKey(_ content: String) -> String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseKeyPair(name: String, privateKey: String, publicKey: String) throws
        -> WireGuardKeyPair
    {
        let privateBase64 = trimKey(privateKey)
        let publicBase64 = trimKey(publicKey)
        guard WireGuardKeys.isValidPrivateKey(privateBase64) else {
            throw StateError.invalidKeyFormat("\(name).key: не base64 длиной 32 байта")
        }
        let pair = try WireGuardKeys.keyPair(name: name, privateKeyBase64: privateBase64)
        guard pair.publicKey == publicBase64 else {
            throw StateError.publicKeyMismatch("\(name).pub не соответствует приватному ключу")
        }
        return pair
    }

    // MARK: obf.conf

    private static func parseKeyValueFile(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=")
            else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(
                in: .whitespaces)
            result[key] = value
        }
        return result
    }

    static func parseObfuscation(_ content: String) throws -> ObfuscationParams {
        let values = parseKeyValueFile(content)
        func int(_ key: String) throws -> Int {
            guard let raw = values[key], let value = Int(raw) else {
                throw StateError.invalidParams("obf.conf: \(key) отсутствует или не число")
            }
            return value
        }
        let params = ObfuscationParams(
            jc: try int("Jc"),
            jmin: try int("Jmin"),
            jmax: try int("Jmax"),
            s1: try int("S1"),
            s2: try int("S2"),
            h1: try int("H1"),
            h2: try int("H2"),
            h3: try int("H3"),
            h4: try int("H4")
        )
        let violations = ObfuscationRules.validate(params)
        if let first = violations.first {
            throw StateError.invalidParams("obf.conf: нарушение правила \(first)")
        }
        return params
    }

    // MARK: env

    /// Разбор содержимого файла env (KEY=VALUE) — публично для экранов статуса/диагностики.
    public static func parseEnvironment(_ content: String) throws -> ChainState.Environment {
        let values = parseKeyValueFile(content)
        guard let bridge = values["BRIDGE"], !bridge.isEmpty else {
            throw StateError.invalidEnvironment("env: BRIDGE отсутствует")
        }
        guard let dockerSubnet = values["DOCKER_SUBNET"], !dockerSubnet.isEmpty else {
            throw StateError.invalidEnvironment("env: DOCKER_SUBNET отсутствует")
        }
        guard let containerIP = values["CONTAINER_IP"], !containerIP.isEmpty else {
            throw StateError.invalidEnvironment("env: CONTAINER_IP отсутствует")
        }
        return ChainState.Environment(
            bridge: bridge,
            dockerSubnet: dockerSubnet,
            containerIP: containerIP,
            containerName: values["CONTAINER_NAME"].flatMap { $0.isEmpty ? nil : $0 },
            clientSubnet: values["CLIENT_SUBNET"].flatMap { $0.isEmpty ? nil : $0 },
            clientPort: values["CLIENT_PORT"].flatMap { $0.isEmpty ? nil : $0 },
            commit: values["COMMIT"].flatMap { $0.isEmpty ? nil : $0 },
            commitTools: values["COMMIT_TOOLS"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
