import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// SSH-транспорт: подключение к серверу и выполнение команд.
///
/// Один экземпляр на сервер; команды выполняются по отдельным session-каналам,
/// поэтому шаги provisioning могут выполняться последовательно на одном соединении.
/// Поток вывода транслируется вызывающей стороне через `onOutput` по мере поступления
/// (колбэк вызывается с event loop thread).
public final class SSHClient: @unchecked Sendable {
    /// Общий event loop group для всех соединений приложения.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    /// Мутабельное состояние соединения. Доступ только через LockedBox.
    struct State {
        var channel: Channel?
        var handler: NIOSSHHandler?
        var eventLoop: EventLoop?
        var didCompleteAuth = false
        var closed = false
        var closeError: Error?
    }

    private let options: SSHConnectOptions
    private let state = LockedBox(State())
    private let fingerprintSink = LockedBox<String?>(nil)

    public init(options: SSHConnectOptions) {
        self.options = options
    }

    // MARK: - Подключение

    /// Устанавливает TCP- и SSH-соединение (handshake + проверка host key).
    /// Аутентификация фактически выполняется при первом exec; здесь проверяется
    /// доступность хоста и согласование параметров соединения.
    public func connect() async throws {
        let validator = HostKeyValidator(
            policy: options.hostKeyPolicy, fingerprintSink: fingerprintSink)
        let bootstrap = ClientBootstrap(group: Self.group)
            .connectTimeout(.seconds(Int64(options.connectTimeout)))
            .channelInitializer { [state, options] channel in
                let config = SSHClientConfiguration(
                    userAuthDelegate: AuthDelegate(method: options.auth, user: options.user),
                    serverAuthDelegate: validator
                )
                let handler = NIOSSHHandler(
                    role: .client(config),
                    allocator: ByteBufferAllocator(),
                    inboundChildChannelInitializer: nil
                )
                state.withLock { s in
                    s.handler = handler
                }
                return channel.pipeline.addHandlers([handler, ConnectionWatcher(state: state)])
            }
        do {
            let channel = try await bootstrap.connect(host: options.host, port: options.port).get()
            state.withLock { s in
                s.channel = channel
                s.eventLoop = channel.eventLoop
            }
        } catch let error as SSHError {
            throw error
        } catch {
            throw SSHError.connectionFailed(
                "\(options.host):\(options.port) — \(error.localizedDescription)")
        }
    }

    /// Отпечаток host key, полученный при последнем подключении (для TOFU в профиле).
    public var seenHostKeyFingerprint: String? {
        fingerprintSink.withLock { $0 }
    }

    public var isConnected: Bool {
        state.withLock { $0.channel != nil && !$0.closed }
    }

    public func close() async {
        let channel = state.withLock { $0.channel }
        guard let channel else { return }
        try? await channel.close().get()
        state.withLock { s in
            s.channel = nil
            s.handler = nil
            s.closed = true
        }
    }

    // MARK: - Выполнение команд

    /// Выполняет команду на сервере.
    ///
    /// - Parameters:
    ///   - command: строка команды (выполняется shell'ом пользователя сервера).
    ///   - timeout: таймаут; по истечении канал закрывается, бросается `SSHError.timeout`.
    ///   - onOutput: потоковый колбэк кусков stdout/stderr по мере поступления.
    public func run(
        _ command: String,
        timeout: TimeInterval? = nil,
        onOutput: (@Sendable (SSHOutputChunk) -> Void)? = nil
    ) async throws -> SSHExecResult {
        let eventLoop = try requireEventLoop()
        let collector = ExecCollector()
        let childChannelBox = LockedBox<Channel?>(nil)
        let handlerBox = LockedBox<NIOSSHHandler?>(state.withLock { $0.handler })

        let future: EventLoopFuture<SSHExecResult> = eventLoop.flatSubmit { [self] in
            guard let handler = handlerBox.withLock({ $0 }) else {
                let completion = eventLoop.makePromise(of: SSHExecResult.self)
                completion.fail(SSHError.closedUnexpectedly("соединение не установлено"))
                return completion.futureResult
            }
            let completion = eventLoop.makePromise(of: SSHExecResult.self)
            let session = ExecSessionHandler(
                command: command,
                collector: collector,
                onOutput: onOutput,
                completion: completion
            )
            let createPromise = eventLoop.makePromise(of: Channel.self)
            handler.createChannel(createPromise, channelType: .session) {
                [childChannelBox] child, _ in
                childChannelBox.withLock { $0 = child }
                return child.pipeline.addHandler(session)
            }
            // Не удалось открыть канал — чаще всего отказ аутентификации.
            createPromise.futureResult.whenComplete { result in
                if case .failure(let error) = result {
                    completion.fail(
                        SSHError.authFailed("канал не открыт: \(error.localizedDescription)"))
                }
            }
            return completion.futureResult
        }

        do {
            let result = try await Self.withTimeout(
                seconds: timeout ?? options.commandTimeout,
                onTimeout: { [childChannelBox] in
                    if let child = childChannelBox.withLock({ $0 }) {
                        _ = child.close()
                    }
                }
            ) { [self] in
                let result = try await future.get()
                state.withLock { $0.didCompleteAuth = true }
                return result
            }
            return result
        } catch let error as SSHError {
            throw error
        } catch {
            throw SSHError.closedUnexpectedly(error.localizedDescription)
        }
    }

    // MARK: - Таймауты

    /// Гонка операции со sleep-таймером. По таймауте вызывает `onTimeout` (закрытие канала)
    /// и бросает `SSHError.timeout`. Выделен отдельно для unit-тестов таймаут-логики.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        onTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = UInt64(max(seconds, 0.001) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw SSHError.timeout("не уложилась в \(seconds) c")
            }
            do {
                guard let first = try await group.next() else {
                    throw SSHError.closedUnexpectedly("нет результата")
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                await onTimeout()
                throw error
            }
        }
    }

    // MARK: - Внутреннее

    private func requireEventLoop() throws -> EventLoop {
        let snapshot = state.withLock {
            ($0.eventLoop, $0.closed, $0.closeError, $0.didCompleteAuth)
        }
        if let loop = snapshot.0, !snapshot.1 {
            return loop
        }
        if snapshot.1, !snapshot.3 {
            throw snapshot.2
                ?? SSHError.authFailed("сервер закрыл соединение до завершения аутентификации")
        }
        throw SSHError.closedUnexpectedly("соединение закрыто")
    }

    // MARK: Отпечаток host key

    /// Отпечаток в формате OpenSSH (`SHA256:base64 без padding`).
    static func fingerprint(of publicKey: NIOSSHPublicKey) -> String {
        let openSSHString = String(openSSHPublicKey: publicKey)
        let base64Part = openSSHString.split(separator: " ")[safe: 1].map(String.init) ?? ""
        guard let keyData = Data(base64Encoded: base64Part) else {
            return "UNKNOWN"
        }
        let digest = SHA256.hash(data: keyData)
        let digestBase64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(digestBase64)"
    }

    static func policyAccepts(_ policy: SSHHostKeyPolicy, fingerprint: String) async -> Bool {
        switch policy {
        case .acceptAll:
            return true
        case .pinned(let expected):
            return fingerprint == expected
        case .tofu(let expected, let confirm):
            if let expected {
                return fingerprint == expected
            }
            return await confirm(fingerprint)
        }
    }
}

// MARK: - NIO-делегаты и обработчики

/// Делегат аутентификации: предлагает серверу единственный настроенный способ.
private final class AuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let method: SSHAuthMethod
    private let user: String

    init(method: SSHAuthMethod, user: String) {
        self.method = method
        self.user = user
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        _ = availableMethods
        switch method {
        case .password(let password):
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: user,
                    serviceName: "ssh-connection",
                    offer: .password(.init(password: password))
                )
            )
        case .key(let material):
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: user,
                    serviceName: "ssh-connection",
                    offer: .privateKey(.init(privateKey: material.privateKey))
                )
            )
        }
    }
}

/// Делегат проверки host key: считает отпечаток и передаёт решение политике (TOFU).
private final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable
{
    private let policy: SSHHostKeyPolicy
    private let fingerprintSink: LockedBox<String?>

    init(policy: SSHHostKeyPolicy, fingerprintSink: LockedBox<String?>) {
        self.policy = policy
        self.fingerprintSink = fingerprintSink
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>
    ) {
        let fingerprint = SSHClient.fingerprint(of: hostKey)
        fingerprintSink.withLock { $0 = fingerprint }
        Task { [policy] in
            let accepted = await SSHClient.policyAccepts(policy, fingerprint: fingerprint)
            if accepted {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHError.hostKeyRejected)
            }
        }
    }
}

/// Наблюдатель основного канала: фиксирует закрытие соединения и ошибки TCP/handshake.
private final class ConnectionWatcher: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private let state: LockedBox<SSHClient.State>

    init(state: LockedBox<SSHClient.State>) {
        self.state = state
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.withLock { $0.closed = true }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state.withLock { $0.closeError = error }
        _ = context.close()
    }
}

/// Обработчик одного exec-канала: отправляет команду, собирает stdout/stderr и код возврата.
/// Создаётся и живёт строго на event loop child-канала.
private final class ExecSessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData

    private let command: String
    private let collector: ExecCollector
    private let onOutput: (@Sendable (SSHOutputChunk) -> Void)?
    private let completion: EventLoopPromise<SSHExecResult>
    private let stdoutAssembler = ChunkAssembler()
    private let stderrAssembler = ChunkAssembler()
    private var finished = false
    private var execSent = false

    init(
        command: String,
        collector: ExecCollector,
        onOutput: (@Sendable (SSHOutputChunk) -> Void)?,
        completion: EventLoopPromise<SSHExecResult>
    ) {
        self.command = command
        self.collector = collector
        self.onOutput = onOutput
        self.completion = completion
    }

    func channelActive(context: ChannelHandlerContext) {
        collector.markOpened()
        if !execSent {
            execSent = true
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                promise: nil
            )
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        let bytes = Array(buffer.readableBytesView)
        switch channelData.type {
        case SSHChannelData.DataType.channel:
            collector.appendStdout(bytes)
            emitChunk(.stdout(stdoutAssembler.append(bytes)))
        case SSHChannelData.DataType.stdErr:
            collector.appendStderr(bytes)
            emitChunk(.stderr(stderrAssembler.append(bytes)))
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as SSHChannelRequestEvent.ExitStatus:
            collector.markExitStatus(event.exitStatus)
            // Все данные уже дошли; закрываем канал — последует channelInactive.
            context.close(promise: nil)
        case let event as SSHChannelRequestEvent.ExitSignal:
            collector.markExitSignal(event.signalName)
            context.close(promise: nil)
        case ChannelEvent.inputClosed:
            collector.markEOF()
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        collector.markInactive()
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        collector.markFailed(error)
        finish()
        context.close(promise: nil)
    }

    private func emitChunk(_ chunk: SSHOutputChunk) {
        onOutput?(chunk)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        completion.succeed(collector.snapshotResult())
    }
}

extension Array {
    /// Безопасное индексирование: nil вместо падения.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Потокобезопасная коробка для значения (обёртка над NSLock).
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
