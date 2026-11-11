import Foundation

/// Входные данные движка: секреты relay-участка и адрес С2.
/// Движок сам решает — переиспользовать ли секреты с серверов (идемпотентность) или взять эти.
public struct ProvisioningInput: Sendable {
    /// Хост/IP Сервера 2 (Endpoint в конфиге С1).
    public let s2Address: String
    /// Резервные секреты: используются, если на С1 нет валидного состояния.
    public let obf: ObfuscationParams
    public let s1Keys: WireGuardKeyPair
    public let s2Keys: WireGuardKeyPair

    public init(s2Address: String, obf: ObfuscationParams, s1Keys: WireGuardKeyPair, s2Keys: WireGuardKeyPair) {
        self.s2Address = s2Address
        self.obf = obf
        self.s1Keys = s1Keys
        self.s2Keys = s2Keys
    }

    /// Свежие секреты по правилам раздела 4 ТЗ.
    public static func fresh(s2Address: String) throws -> ProvisioningInput {
        ProvisioningInput(
            s2Address: s2Address,
            obf: ObfuscationRules.generate(),
            s1Keys: try WireGuardKeys.generateKeyPair(name: "s1-relay"),
            s2Keys: try WireGuardKeys.generateKeyPair(name: "s2-relay")
        )
    }
}

/// Прогресс шага для UI (задача 5.5).
public struct StepProgress: Sendable, Equatable {
    public enum State: String, Sendable {
        case pending, running, done, failed, skipped
    }

    public let stepID: String
    public let state: State
    public let detail: String?

    public init(stepID: String, state: State, detail: String? = nil) {
        self.stepID = stepID
        self.state = state
        self.detail = detail
    }
}

/// FSM-движок provisioning (задача 5.4, design D4).
///
/// Фиксированный порядок (С2 раньше С1, чтобы клиенты не ушли в blackhole
/// до готовности выхода): Detect(C1) → Install(C2) → Install(C1) →
/// Configure(C2) → Configure(C1) → Verify(handshake).
/// Каждый шаг идемпотентен; шаги из `completedSteps` пропускаются
/// (кроме detect — он всегда перечитывает состояние, design D5).
public final class ProvisioningEngine: @unchecked Sendable {
    public static let stepOrder = [
        "detect-c1",
        "install-c2",
        "install-c1",
        "configure-c2",
        "configure-c1",
        "verify-handshake",
    ]

    public struct Options: Sendable {
        /// Попытки дождаться handshake между С1 и С2.
        public var verifyAttempts = 10
        /// Пауза между попытками, секунды.
        public var verifyDelay: TimeInterval = 15
        /// Таймаут обычной команды.
        public var commandTimeout: TimeInterval = 300

        public init(verifyAttempts: Int = 10, verifyDelay: TimeInterval = 15, commandTimeout: TimeInterval = 300) {
            self.verifyAttempts = verifyAttempts
            self.verifyDelay = verifyDelay
            self.commandTimeout = commandTimeout
        }
    }

    /// Ошибки верификации handshake.
    public enum VerifyError: Error, Equatable {
        case handshakeNotSeen(attempts: Int)
    }

    private let c1: any RemoteRunner
    private let c2: any RemoteRunner
    private let input: ProvisioningInput
    private let options: Options
    private let onProgress: @Sendable (StepProgress) -> Void
    private let onLog: @Sendable (ServerRole, String) -> Void

    /// Состояние, накопленное шагами (детект → конфигурация).
    private let stateBox: LockedBox<(containerName: String?, environment: ChainState.Environment?, secrets: ProvisioningInput?)> = .init((nil, nil, nil))

    public init(
        c1: any RemoteRunner,
        c2: any RemoteRunner,
        input: ProvisioningInput,
        options: Options = Options(),
        onProgress: @escaping @Sendable (StepProgress) -> Void = { _ in },
        onLog: @escaping @Sendable (ServerRole, String) -> Void = { _, _ in }
    ) {
        self.c1 = c1
        self.c2 = c2
        self.input = input
        self.options = options
        self.onProgress = onProgress
        self.onLog = onLog
    }

    /// Полный прогон. Возвращает детектированное окружение С1.
    @discardableResult
    public func run(completedSteps: Set<String> = []) async throws -> ChainState.Environment {
        for stepID in Self.stepOrder {
            // Detect всегда выполняется: дешёвый и обновляет состояние (design D5).
            if completedSteps.contains(stepID), stepID != "detect-c1" {
                emit(stepID, .skipped, "пропущен: уже выполнен ранее")
                continue
            }
            emit(stepID, .running, nil)
            do {
                let detail: String?
                switch stepID {
                case "detect-c1": detail = try await runDetect()
                case "install-c2": detail = try await installSoftware(on: c2, role: .exit)
                case "install-c1": detail = try await installSoftware(on: c1, role: .entry)
                case "configure-c2": detail = try await configureC2()
                case "configure-c1": detail = try await configureC1()
                case "verify-handshake": detail = try await verifyHandshake()
                default:
                    throw ProvisioningError.parseFailed("неизвестный шаг \(stepID)")
                }
                emit(stepID, .done, detail)
            } catch {
                emit(stepID, .failed, "\(error)")
                throw error
            }
        }
        guard let environment = stateBox.withLock({ $0.environment }) else {
            throw ProvisioningError.parseFailed("окружение С1 не определено")
        }
        return environment
    }

    // MARK: Внутреннее

    private func emit(_ stepID: String, _ state: StepProgress.State, _ detail: String?) {
        onProgress(StepProgress(stepID: stepID, state: state, detail: detail))
    }

    private func log(_ role: ServerRole, _ line: String) {
        onLog(role, line)
    }

    /// Detect(C1) + идемпотентная работа с секретами.
    private func runDetect() async throws -> String {
        let detection = try await EnvironmentDetector(runner: c1, exitRoutesRunner: c2).detect()

        // Пытаемся переиспользовать существующие секреты (ТЗ раздел 5: идемпотентность).
        var secrets = input
        var reused = false
        let loadCommand = """
        for f in s1-relay.key s1-relay.pub s2-relay.key s2-relay.pub obf.conf; do echo "==VPNCHAIN-FILE $f=="; cat /etc/amnezia/chain/$f 2>/dev/null; done
        """
        let existing = try await c1.run(loadCommand, timeout: 30, onOutput: nil)
        if let state = try? Self.parseExistingState(existing.stdout, environment: detection.environment) {
            secrets = ProvisioningInput(
                s2Address: input.s2Address,
                obf: state.obf,
                s1Keys: state.s1,
                s2Keys: state.s2
            )
            reused = true
        }

        // Раскладываем состояние на С1: ключи обеих сторон, параметры, env.
        let environment = ChainState.Environment(
            bridge: detection.environment.bridge,
            dockerSubnet: detection.environment.dockerSubnet,
            containerIP: detection.environment.containerIP,
            containerName: detection.containerName,
            clientSubnet: detection.environment.clientSubnet,
            clientPort: detection.environment.clientPort,
            commit: AmneziaPins.goDaemon,
            commitTools: AmneziaPins.tools
        )
        let deliveries = [
            FileDelivery.command(path: "/etc/amnezia/chain/s1-relay.key", content: secrets.s1Keys.privateKey),
            FileDelivery.command(path: "/etc/amnezia/chain/s1-relay.pub", content: secrets.s1Keys.publicKey),
            FileDelivery.command(path: "/etc/amnezia/chain/s2-relay.key", content: secrets.s2Keys.privateKey),
            FileDelivery.command(path: "/etc/amnezia/chain/s2-relay.pub", content: secrets.s2Keys.publicKey),
            FileDelivery.command(path: "/etc/amnezia/chain/obf.conf", content: secrets.obf.ordered.map { "\($0.name)=\($0.value)" }.joined(separator: "\n")),
            FileDelivery.command(path: "/etc/amnezia/chain/env", content: environment.fileContent),
        ].joined(separator: "\n")
        let stateResult = try await c1.run(deliveries, timeout: 60, onOutput: nil)
        guard stateResult.succeeded else {
            throw ProvisioningError.commandFailed(step: "detect-c1", exitCode: stateResult.exitCode, stderr: stateResult.stderr)
        }

        stateBox.withLock { box in
            box.containerName = detection.containerName
            box.environment = environment
            box.secrets = secrets
        }
        let migrationNote = detection.migratedFromDefaultBridge
            ? "Контейнер \(detection.containerName) перенесён с дефолтного bridge на выделенную сеть \(detection.environment.bridge) (\(detection.environment.dockerSubnet)). "
            : ""
        return migrationNote + (reused
            ? "переиспользованы существующие секреты (идемпотентность)"
            : "сгенерированы новые ключи и параметры обфускации")
    }

    /// Разбор ранее сохранённого состояния (секреты из файлов С1 + окружение из детекта).
    static func parseExistingState(_ output: String, environment: ChainState.Environment) throws -> ChainState {
        var files: [String: String] = [:]
        var currentFile: String?
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("==VPNCHAIN-FILE "), trimmed.hasSuffix("==") {
                currentFile = String(trimmed.dropFirst("==VPNCHAIN-FILE ".count).dropLast(2))
                files[currentFile!] = ""
            } else if let file = currentFile {
                files[file]?.append(line + "\n")
            }
        }
        var allFiles = files
        allFiles["env"] = environment.fileContent
        return try ChainStateParser.parse(files: allFiles)
    }

    /// Установка ПО (ТЗ раздел 3): платформа → план → check-then-apply → Go-решение.
    func installSoftware(on runner: any RemoteRunner, role: ServerRole) async throws -> String {
        // Платформа.
        let probe = try await runner.run(PlatformParser.probeCommand, timeout: 30, onOutput: nil)
        let platform = try PlatformParser.parseProbeOutput(probe.stdout)
        try PlatformParser.ensureSupported(platform)
        log(role, "платформа: \(platform.displayName)")

        var installedFallbackGo = false
        for action in SoftwareInstallPlan.actions(platform: platform) {
            if let check = action.check {
                let checkResult = try await runner.run(check, timeout: 60, onOutput: nil)
                if !ShellAction.shouldApply(checkExitCode: checkResult.exitCode) {
                    log(role, "пропущено: \(action.title)")
                    // Решение по Go обязательно и на повторном прогоне: клон уже есть,
                    // но без него fallback пропускается и сборка падает с «go: not found».
                    if action.id == "go-source" {
                        installedFallbackGo = try await resolveGoAndFallback(on: runner, role: role, arch: platform.arch)
                    }
                    continue
                }
            }
            try await apply(action, on: runner, role: role)

            // Go-решение принимается ПОСЛЕ клона amneziawg-go: без go.mod
            // fallback-действие пропускается и сборка падает с «go: not found».
            if action.id == "go-source" {
                installedFallbackGo = try await resolveGoAndFallback(on: runner, role: role, arch: platform.arch)
            }
            if action.id == "go-build", installedFallbackGo {
                log(role, "сборка выполнена свежим Go из /usr/local/go")
            }
        }
        return "ПО amneziawg установлено"
    }

    /// Go-решение: сверка go.mod с системным Go, при необходимости — установка свежего
    /// из tarball. Возвращает: был ли установлен fallback. `.invalid` роняет установку сразу.
    private func resolveGoAndFallback(
        on runner: any RemoteRunner,
        role: ServerRole,
        arch: ServerPlatform.Arch
    ) async throws -> Bool {
        let decision = try await resolveGoDecision(on: runner, role: role, arch: arch)
        switch decision {
        case .fallbackRequired(let required):
            let fallback = SoftwareInstallPlan.goFallbackAction(required: required, arch: arch)
            try await apply(fallback, on: runner, role: role)
            return true
        case .invalid(let detail):
            // Молча продолжать нельзя: сборка заведомо упадёт с «go: not found».
            throw ProvisioningError.parseFailed("go.mod: \(detail)")
        case .systemSufficient:
            return false
        }
    }

    /// Решение по Go: версия из go.mod склонированного репозитория против системной.
    private func resolveGoDecision(on runner: any RemoteRunner, role: ServerRole, arch: ServerPlatform.Arch) async throws -> GoDecision {
        let goModResult = try await runner.run("grep '^go ' \(SoftwareInstallPlan.goDir)/go.mod", timeout: 30, onOutput: nil)
        let goVersionResult = try? await runner.run("go version", timeout: 30, onOutput: nil)
        let decision = SoftwareInstallPlan.goBinaryDecision(
            goModOutput: goModResult.stdout,
            goVersionOutput: (try? goVersionResult)?.stdout ?? goVersionResult?.stdout ?? ""
        )
        log(role, "go: \(decision)")
        return decision
    }

    private func apply(_ action: ShellAction, on runner: any RemoteRunner, role: ServerRole) async throws {
        log(role, "→ \(action.title)")
        let result = try await runner.run(action.apply, timeout: action.timeout) { [log] chunk in
            log(role, "\(chunk)")
        }
        guard result.succeeded else {
            // Автосбор журнала упавшего юнита — без него видна только общая фраза systemd.
            let diagCommand = Self.failureDiagnosticsCommand(for: action)
            var journal = ""
            if diagCommand != "true" {
                if let diag = try? await runner.run(diagCommand, timeout: 30, onOutput: nil), !diag.stdout.isEmpty {
                    journal = "\n--- журнал юнита ---\n" + diag.stdout
                    log(role, journal)
                }
            }
            throw ProvisioningError.commandFailed(
                step: action.id,
                exitCode: result.exitCode,
                stderr: result.stderr + journal
            )
        }
    }

    /// Диагностические команды после падения шага: журнал и трассировка задетого юнита/скрипта.
    ///
    /// «vpn-chain» проверяется до «awg-quick@awg-relay»: в `After=` юнита
    /// `vpn-chain-exit` упоминается `awg-quick@awg-relay.service`, и менее
    /// специфичный матчинг вытягивал чужой журнал.
    static func failureDiagnosticsCommand(for action: ShellAction) -> String {
        var parts: [String] = []
        if action.apply.contains("vpn-chain-exit-rules.sh") {
            parts.append("bash -x /usr/local/bin/vpn-chain-exit-rules.sh 2>&1 | tail -40 || true")
        }
        if action.apply.contains("vpn-chain-rules.sh") {
            parts.append("bash -x /usr/local/bin/vpn-chain-rules.sh 2>&1 | tail -40 || true")
        }
        if action.apply.contains("vpn-chain") {
            parts.append("journalctl -u vpn-chain.service -u vpn-chain-exit.service --no-pager -n 25 2>/dev/null | tail -30")
            parts.append("systemctl status vpn-chain-exit.service --no-pager 2>/dev/null | head -12")
        }
        // Для собственных действий по awg-quick (enable/stop). Упоминание awg-quick
        // внутри юнита vpn-chain-exit (строка After=) чужой журнал не тянет.
        if action.apply.contains("awg-quick@awg-relay"), !action.apply.contains("vpn-chain") {
            parts.append("journalctl -u awg-quick@awg-relay --no-pager -n 25 2>/dev/null | tail -30")
            parts.append("systemctl status awg-quick@awg-relay --no-pager 2>/dev/null | head -12")
        }
        guard !parts.isEmpty else { return "true" }
        return parts.joined(separator: "\n") + "\ntrue"
    }

    /// Configure C2: конфиг 9.2, включение relay, правила выхода.
    private func configureC2() async throws -> String {
        let (environment, secrets) = stateBox.withLock { ($0.environment, $0.secrets) }
        guard let environment, let secrets else {
            throw ProvisioningError.parseFailed("детект не выполнен")
        }
        // WAN-интерфейс С2.
        let routeResult = try await c2.run(ConfigureC2.wanDetectCommand, timeout: 30, onOutput: nil)
        guard let wan = ConfigureC2.parseDefaultInterface(routeResult.stdout) else {
            throw ProvisioningError.parseFailed("не удалось определить WAN-интерфейс С2")
        }
        let config = ConfigTemplates.renderC2(
            obf: secrets.obf,
            s2PrivateKey: secrets.s2Keys.privateKey,
            s1RelayPublicKey: secrets.s1Keys.publicKey,
            dockerSubnet: environment.dockerSubnet,
            clientSubnet: environment.clientSubnet
        )
        for action in ConfigureC2.actions(configContent: config, wanInterface: wan, dockerSubnet: environment.dockerSubnet, clientSubnet: environment.clientSubnet) {
            try await apply(action, on: c2, role: .exit)
        }
        return "конфигурация С2 применена (WAN: \(wan))"
    }

    /// Configure C1: конфиг 9.1, юнит awg-quick, policy routing + kill-switch.
    private func configureC1() async throws -> String {
        let (environment, secrets) = stateBox.withLock { ($0.environment, $0.secrets) }
        guard let environment, let secrets else {
            throw ProvisioningError.parseFailed("детект не выполнен")
        }
        // Без порта клиентского AWG нельзя безопасно отличить ответы контейнера клиентам
        // от клиентского трафика — правила не применяем (регрессия приёмки: клиент не мог
        // подключиться, т.к. его handshake уходил в relay-туннель).
        guard let clientPort = environment.clientPort, !clientPort.isEmpty else {
            throw ProvisioningError.parseFailed(
                "не удалось определить порт клиентского AWG (ListenPort в конфиге контейнера \(environment.containerName ?? "amnezia-awg")): правила policy routing не применены, чтобы не нарушить подключение клиентов"
            )
        }
        let config = ConfigTemplates.renderC1(
            obf: secrets.obf,
            s1PrivateKey: secrets.s1Keys.privateKey,
            s2RelayPublicKey: secrets.s2Keys.publicKey,
            s2IP: input.s2Address
        )
        for action in ConfigureC1.actions(configContent: config, bridge: environment.bridge, clientPort: clientPort) {
            try await apply(action, on: c1, role: .entry)
        }
        return "конфигурация С1 применена"
    }

    /// Verify: handshake С1↔С2 в пределах попыток (ТЗ раздел 10, пункт 2).
    private func verifyHandshake() async throws -> String {
        for attempt in 1...options.verifyAttempts {
            let result = try await c1.run("awg show awg-relay", timeout: 30, onOutput: nil)
            if Self.handshakeSeen(result.stdout) {
                return "handshake установлен (попытка \(attempt)/\(options.verifyAttempts))"
            }
            if attempt < options.verifyAttempts {
                try await Task.sleep(nanoseconds: UInt64(options.verifyDelay * 1_000_000_000))
            }
        }
        throw VerifyError.handshakeNotSeen(attempts: options.verifyAttempts)
    }

    /// Handshake считается состоявшимся при наличии строки `latest handshake:` у пира.
    public static func handshakeSeen(_ awgShowOutput: String) -> Bool {
        awgShowOutput.contains("latest handshake:")
    }
}
