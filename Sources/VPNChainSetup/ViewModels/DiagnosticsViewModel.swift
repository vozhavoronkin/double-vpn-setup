import Foundation
import VPNChainCore

/// ViewModel экрана «Диагностика» (задача 6.5): симптомы → проверки → советы,
/// плюс корректный uninstall по ролям.
@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published var selectedSymptom: Symptom = .noHandshake
    @Published private(set) var guide: SymptomGuide?
    @Published private(set) var checkResults: [CheckResult] = []
    @Published private(set) var diagnosing = false
    @Published private(set) var uninstalling: ServerRole?
    @Published private(set) var uninstallReport: String?
    @Published private(set) var errorText: String?

    private let store: ProfileStore

    init(store: ProfileStore) {
        self.store = store
    }

    /// Сколько проверок пройдено (для сводки результатов).
    var passedCount: Int {
        checkResults.filter(\.passed).count
    }

    /// Всего проверок, по которым есть результат.
    var totalCount: Int {
        checkResults.count
    }

    /// Чтение окружения С1 (может отсутствовать).
    private func readEnvironment(on c1: any RemoteRunner) async -> ChainState.Environment? {
        guard let result = try? await c1.run(StatusParsers.environmentCommand, timeout: 30, onOutput: nil),
              result.succeeded || !result.stdout.isEmpty else {
            return nil
        }
        return try? ChainStateParser.parseEnvironment(result.stdout)
    }

    /// Диагностика выбранного симптома: гайд + автоматические проверки.
    func diagnose() {
        guard !diagnosing else { return }
        diagnosing = true
        errorText = nil
        checkResults = []
        let store = self.store
        Task {
            defer { Task { @MainActor [weak self] in self?.diagnosing = false } }
            do {
                let checker = ConnectionChecker(store: store) { fingerprint in
                    await ConnectionsViewModel.confirmFingerprint(host: "", fingerprint: fingerprint)
                }
                guard let entry = store.profile(for: .entry), let exit = store.profile(for: .exit) else {
                    throw ConnectionChecker.CheckError.profileInvalid("настройте оба подключения")
                }
                let c1 = SSHClient(options: try checker.connectOptions(for: entry))
                let c2 = SSHClient(options: try checker.connectOptions(for: exit))
                try await c1.connect()
                try await c2.connect()
                defer { Task { await c1.close(); await c2.close() } }

                let environment = await readEnvironment(on: c1)
                let guide = Troubleshooting.guide(for: selectedSymptom, environment: environment, s2Address: exit.host)
                self.guide = guide
                self.checkResults = await ChecksEngine.runAll(guide.checks, entry: c1, exit: c2)
            } catch {
                self.errorText = UserMessages.text(of: error)
            }
        }
    }

    /// Uninstall для роли. Возвращает отчёт (частичный успех — при недоступности сервера).
    func uninstall(_ role: ServerRole, alsoSoftware: Bool) {
        guard uninstalling == nil else { return }
        uninstalling = role
        uninstallReport = nil
        errorText = nil

        let store = self.store
        Task {
            defer { Task { @MainActor [weak self] in self?.uninstalling = nil } }
            do {
                // Для uninstall сервера-выхода нужна подсеть из env сервера-входа (best effort).
                var environment: ChainState.Environment?
                if role == .exit, let entry = store.profile(for: .entry) {
                    let checker = ConnectionChecker(store: store) { fingerprint in
                        await ConnectionsViewModel.confirmFingerprint(host: "", fingerprint: fingerprint)
                    }
                    let entryClient = try? SSHClient(options: checker.connectOptions(for: entry))
                    try? await entryClient?.connect()
                    if let entryClient {
                        environment = await readEnvironment(on: entryClient)
                        await entryClient.close()
                    }
                }

                guard let profile = role == .entry ? store.profile(for: .entry) : store.profile(for: .exit) else {
                    uninstallReport = "профиль сервера не настроен"
                    return
                }
                let checker = ConnectionChecker(store: store) { fingerprint in
                    await ConnectionsViewModel.confirmFingerprint(host: "", fingerprint: fingerprint)
                }
                let target = SSHClient(options: try checker.connectOptions(for: profile))
                try await target.connect()
                defer { Task { await target.close() } }

                // Окружение можно снять и с самого целевого сервера (если он — сервер-вход).
                let envOnTarget = await readEnvironment(on: target)
                let effectiveEnvironment = environment ?? envOnTarget

                let commands: [UninstallCommand]
                let roleTitle = role == .entry ? "сервер-вход" : "сервер-выход"
                if role == .entry {
                    commands = UninstallPlan.entryCommands()
                } else {
                    guard let dockerSubnet = effectiveEnvironment?.dockerSubnet else {
                        uninstallReport = """
                        не удалось определить Docker-подсеть сервера-входа (нет связи с ним) — \
                        повторите очистку позже; MASQUERADE удалите вручную
                        """
                        return
                    }
                    commands = UninstallPlan.exitCommands(dockerSubnet: dockerSubnet, clientSubnet: effectiveEnvironment?.clientSubnet)
                }

                var failed: [String] = []
                for command in commands {
                    let result = try await target.run(command.command, timeout: 120, onOutput: nil)
                    if !result.succeeded {
                        failed.append("\(command.title): код \(result.exitCode ?? -1) \(result.stderr)")
                    }
                }
                if alsoSoftware {
                    for command in UninstallPlan.optionalSoftwareRemoval {
                        _ = try? await target.run(command.command, timeout: 60, onOutput: nil)
                    }
                }

                if failed.isEmpty {
                    uninstallReport = "\(roleTitle): очистка завершена, маркеры и правила удалены. SSH и контейнер AmneziaVPN не затронуты."
                } else {
                    uninstallReport = "\(roleTitle): очистка завершена частично:\n" + failed.joined(separator: "\n")
                }
            } catch {
                uninstallReport = nil
                errorText = UserMessages.text(of: error)
            }
        }
    }
}
