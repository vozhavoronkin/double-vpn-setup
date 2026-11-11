import Foundation
import VPNChainCore

/// ViewModel экрана «Статус» (задача 6.5): снапшот цепочки + автоматические проверки.
@MainActor
final class StatusViewModel: ObservableObject {
    @Published private(set) var snapshot: ChainStatusSnapshot?
    @Published private(set) var checkResults: [CheckResult] = []
    @Published private(set) var refreshing = false
    @Published private(set) var errorText: String?
    @Published private(set) var environment: ChainState.Environment?

    private let store: ProfileStore

    init(store: ProfileStore) {
        self.store = store
    }

    /// Собирает снапшот и прогоняет автоматические проверки раздела 10 ТЗ.
    func refresh() {
        guard !refreshing, let entry = store.profile(for: .entry), let exit = store.profile(for: .exit) else { return }
        refreshing = true
        errorText = nil
        let checker = ConnectionChecker(store: store) { fingerprint in
            await ConnectionsViewModel.confirmFingerprint(host: "", fingerprint: fingerprint)
        }

        Task { [weak self] in
            defer { self?.refreshing = false }
            do {
                let c1 = SSHClient(options: try checker.connectOptions(for: entry))
                let c2 = SSHClient(options: try checker.connectOptions(for: exit))
                try await c1.connect()
                try await c2.connect()
                defer { Task { await c1.close(); await c2.close() } }

                // Окружение может отсутствовать (цепочка не развёрнута) — часть проверок тогда скрыта.
                let envResult = try? await c1.run(StatusParsers.environmentCommand, timeout: 30, onOutput: nil)
                let environment = envResult.flatMap { try? ChainStateParser.parseEnvironment($0.stdout) }
                self?.environment = environment

                let collector = StatusCollector(environment: environment)
                let snapshot = await collector.snapshot(c1: c1, c2: c2)
                self?.snapshot = snapshot

                let checks = ChecksEngine.automatedChecks(environment: environment)
                self?.checkResults = await ChecksEngine.runAll(checks, entry: c1, exit: c2)
            } catch {
                self?.errorText = UserMessages.text(of: error)
            }
        }
    }
}
