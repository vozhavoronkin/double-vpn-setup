import Foundation

/// Потокобезопасный аккумулятор результата одной exec-команды.
///
/// Наполняется из NIO-обработчика канала (event loop), читается из async-кода.
/// Отделён от обработчика, чтобы покрываться unit-тестами без сети.
public final class ExecCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutAssembler = ChunkAssembler()
    private let stderrAssembler = ChunkAssembler()
    private var stdoutText = ""
    private var stderrText = ""
    private var exitCode: Int?
    private var exitSignal: String?

    public init() {}

    // MARK: Вызовы из обработчика канала (event loop)

    public func markOpened() {
        lock.lock()
        defer { lock.unlock() }
    }

    public func appendStdout(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        stdoutText += stdoutAssembler.append(bytes)
    }

    public func appendStderr(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        stderrText += stderrAssembler.append(bytes)
    }

    public func markExitStatus(_ code: Int) {
        lock.lock()
        defer { lock.unlock() }
        exitCode = code
    }

    public func markExitSignal(_ signal: String) {
        lock.lock()
        defer { lock.unlock() }
        exitSignal = signal
    }

    public func markEOF() {
        // EOF учитывается обработчиком канала; здесь без состояния.
        lock.lock()
        defer { lock.unlock() }
    }

    public func markInactive() {
        lock.lock()
        defer { lock.unlock() }
    }

    public func markFailed(_ error: Error) {
        _ = error
        lock.lock()
        defer { lock.unlock() }
    }

    /// Итоговый результат. Вызывается однократно при завершении канала:
    /// сбрасывает хвосты ассемблеров (в т.ч. оборванные байты).
    public func snapshotResult() -> SSHExecResult {
        lock.lock()
        defer { lock.unlock() }
        let stdoutRest = stdoutAssembler.finalize()
        let stderrRest = stderrAssembler.finalize()
        return SSHExecResult(
            exitCode: exitCode,
            stdout: stdoutText + stdoutRest,
            stderr: stderrText + stderrRest,
            exitSignal: exitSignal
        )
    }
}
