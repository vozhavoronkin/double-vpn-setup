import AppKit
import Foundation
import VPNChainCore

/// ViewModel экрана «Установка» (задача 5.5): FSM-прогон с прогрессом,
/// живой вывод команд и итоговая сводка с подсказкой про UDP 51828.
@MainActor
final class InstallViewModel: ObservableObject {
    struct StepRow: Identifiable, Equatable {
        let id: String
        let title: String
        var state: StepProgress.State
        var detail: String?
    }

    @Published private(set) var steps: [StepRow]
    @Published private(set) var logLines: [String] = []
    @Published private(set) var running = false
    @Published private(set) var summary: String?
    @Published private(set) var errorText: String?

    private let store: ProfileStore

    private static let titles: [String: String] = [
        "detect-c1": "Детект окружения сервера-входа",
        "install-c2": "Установка ПО на сервер-выход",
        "install-c1": "Установка ПО на сервер-вход",
        "configure-c2": "Конфигурация сервера-выхода",
        "configure-c1": "Конфигурация сервера-входа и policy routing",
        "verify-handshake": "Проверка handshake",
    ]

    init(store: ProfileStore) {
        self.store = store
        steps = ProvisioningEngine.stepOrder.map { stepID in
            StepRow(id: stepID, title: Self.titles[stepID] ?? stepID, state: .pending, detail: nil)
        }
    }

    var canStart: Bool {
        !running
            && store.profile(for: .entry).map { store.isReady($0) } == true
            && store.profile(for: .exit).map { store.isReady($0) } == true
    }

    /// Сколько шагов уже завершено (успех или пропуск) — для прогресс-бара.
    var completedCount: Int {
        steps.filter { $0.state == .done || $0.state == .skipped }.count
    }

    /// Доля завершённых шагов (0…1).
    var progressFraction: Double {
        steps.isEmpty ? 0 : Double(completedCount) / Double(steps.count)
    }

    /// Подпись прогресса: во время прогона показывает текущий шаг, после — итог.
    var progressTitle: String {
        if running, let index = steps.firstIndex(where: { $0.state == .running }) {
            return "Шаг \(index + 1) из \(steps.count)"
        }
        return "Выполнено \(completedCount) из \(steps.count)"
    }

    /// Причина, по которой установка недоступна (для подсказки в UI).
    var readinessHint: String? {
        if running { return nil }
        guard let entry = store.profile(for: .entry), store.isReady(entry) else {
            return "Настройте и проверьте подключение к серверу-входу во вкладке «Подключения»"
        }
        guard let exit = store.profile(for: .exit), store.isReady(exit) else {
            return "Настройте и проверьте подключение к серверу-выходу во вкладке «Подключения»"
        }
        return nil
    }

    func start() {
        guard canStart, let entry = store.profile(for: .entry), let exit = store.profile(for: .exit) else { return }
        running = true
        summary = nil
        errorText = nil
        logLines = []
        steps = ProvisioningEngine.stepOrder.map { stepID in
            StepRow(id: stepID, title: Self.titles[stepID] ?? stepID, state: .pending, detail: nil)
        }

        let checker = ConnectionChecker(store: store) { [weak self] fingerprint in
            await Self.confirmFingerprint(host: "", fingerprint: fingerprint)
        }

        Task { [weak self] in
            do {
                let c1Options = try checker.connectOptions(for: entry)
                let c2Options = try checker.connectOptions(for: exit)
                let c1 = SSHClient(options: c1Options)
                let c2 = SSHClient(options: c2Options)
                try await c1.connect()
                try await c2.connect()
                defer { Task { await c1.close(); await c2.close() } }

                let input = try ProvisioningInput.fresh(s2Address: exit.host)
                let engine = ProvisioningEngine(
                    c1: c1,
                    c2: c2,
                    input: input,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.apply(progress)
                        }
                    },
                    onLog: { [weak self] role, line in
                        Task { @MainActor [weak self] in
                            self?.appendLog(role: role, line: line)
                        }
                    }
                )
                let environment = try await engine.run()

                self?.summary = Self.summaryText(environment: environment, s2Address: exit.host)
            } catch {
                self?.errorText = UserMessages.text(of: error)
            }
            self?.running = false
        }
    }

    private func apply(_ progress: StepProgress) {
        if let index = steps.firstIndex(where: { $0.id == progress.stepID }) {
            steps[index].state = progress.state
            steps[index].detail = progress.detail
        }
    }

    /// Копирует журнал в буфер обмена. Журнал уже санитизирован при записи,
    /// поэтому отдельного пути для секретов не появляется.
    func copyLogToPasteboard() {
        guard !logLines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logLines.joined(separator: "\n"), forType: .string)
    }

    private func appendLog(role: ServerRole, line: String) {
        logLines.append("[\(role == .entry ? "вход" : "выход")] \(line)")
        if logLines.count > 800 {
            logLines.removeFirst(logLines.count - 800)
        }
    }

    private static func confirmFingerprint(host: String, fingerprint: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Неизвестный сервер"
            alert.informativeText = "Сервер представился отпечатком:\n\n\(fingerprint)\n\nПринять?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Принять")
            alert.addButton(withTitle: "Отклонить")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private static func summaryText(environment: ChainState.Environment, s2Address: String) -> String {
        """
        Цепочка развёрнута.

        Сервер-вход: интерфейс входа \(environment.bridge), Docker-подсеть \(environment.dockerSubnet), IP контейнера \(environment.containerIP)
        Порт клиентского AWG: \(environment.clientPort ?? "не определён")
        \(environment.clientSubnet.map { "Клиентская подсеть AWG: \($0)" } ?? "Клиентская подсеть AWG: не определена (MASQUERADE только по Docker-подсети)")
        Relay-туннель: 10.99.0.0/24, порт UDP 51828, Endpoint \(s2Address):51828

        ВАЖНО: откройте UDP 51828 в firewall/cloud-панели провайдера сервера-выхода,
        затем подключитесь клиентом AmneziaVPN к серверу-входу —
        внешний IP будет адресом сервера-выхода.
        """
    }
}
