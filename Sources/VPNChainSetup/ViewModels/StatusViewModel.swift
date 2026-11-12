import Foundation
import VPNChainCore

/// ViewModel экрана «Статус» (задача 6.5): снапшот цепочки + автоматические проверки.
@MainActor
final class StatusViewModel: ObservableObject {
    /// Итоговый вердикт по цепочке для hero-карточки.
    enum ChainHealth: Equatable {
        case notChecked
        case ok
        case attention
        case offline

        /// Заголовок вердикта для интерфейса.
        var title: String {
            switch self {
            case .notChecked: "Статус не проверялся"
            case .ok: "Цепочка работает"
            case .attention: "Требует внимания"
            case .offline: "Нет связи"
            }
        }

        /// Пояснение, что именно означает вердикт.
        var detail: String {
            switch self {
            case .notChecked: "Обновите статус, чтобы увидеть состояние звеньев"
            case .ok: "Оба сервера доступны, проверки пройдены"
            case .attention: "Часть проверок не пройдена — смотрите подсказки ниже"
            case .offline: "Хотя бы одно звено цепочки недоступно"
            }
        }
    }

    @Published private(set) var snapshot: ChainStatusSnapshot?
    @Published private(set) var checkResults: [CheckResult] = []
    @Published private(set) var refreshing = false
    @Published private(set) var errorText: String?
    @Published private(set) var environment: ChainState.Environment?
    @Published private(set) var lastUpdatedAt: Date?

    private let store: ProfileStore

    init(store: ProfileStore) {
        self.store = store
    }

    // MARK: Производные значения для интерфейса

    /// Итоговый вердикт: недоступность серверов отличаем от непройденных проверок.
    var overallHealth: ChainHealth {
        guard snapshot != nil || !checkResults.isEmpty || errorText != nil else {
            return .notChecked
        }
        if snapshot == nil { return .offline }
        let unreachable = [isUnreachable(snapshot?.entry), isUnreachable(snapshot?.exit)].filter {
            $0
        }.count
        if unreachable == 2 { return .offline }
        if unreachable == 1 { return .attention }
        if checkResults.isEmpty { return .notChecked }
        return checkResults.contains { !$0.passed } ? .attention : .ok
    }

    var passedCount: Int {
        checkResults.filter(\.passed).count
    }

    var failedCount: Int {
        checkResults.count - passedCount
    }

    var entryHost: String? {
        store.profile(for: .entry)?.host
    }

    var exitHost: String? {
        store.profile(for: .exit)?.host
    }

    /// Собирает снапшот и прогоняет автоматические проверки раздела 10 ТЗ.
    func refresh() {
        guard !refreshing else { return }
        guard let entry = store.profile(for: .entry), let exit = store.profile(for: .exit) else {
            errorText = "Настройте оба подключения в разделе «Подключения», затем обновите статус"
            return
        }
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
                defer {
                    Task {
                        await c1.close()
                        await c2.close()
                    }
                }

                // Окружение может отсутствовать (цепочка не развёрнута) — часть проверок тогда скрыта.
                let envResult = try? await c1.run(
                    StatusParsers.environmentCommand, timeout: 30, onOutput: nil)
                let environment = envResult.flatMap {
                    try? ChainStateParser.parseEnvironment($0.stdout)
                }
                self?.environment = environment

                let collector = StatusCollector(environment: environment)
                let snapshot = await collector.snapshot(c1: c1, c2: c2)
                self?.snapshot = snapshot

                let checks = ChecksEngine.automatedChecks(environment: environment)
                self?.checkResults = await ChecksEngine.runAll(checks, entry: c1, exit: c2)
                self?.lastUpdatedAt = Date()
            } catch {
                self?.errorText = UserMessages.text(of: error)
            }
        }
    }

    private func isUnreachable<T: Sendable>(_ availability: ServerAvailability<T>?) -> Bool {
        guard let availability else { return false }
        if case .unreachable = availability { return true }
        return false
    }
}
