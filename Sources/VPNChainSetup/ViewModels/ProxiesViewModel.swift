import Foundation
import VPNChainCore

/// ViewModel экрана «Прокси»: список Docker-сетей сервера-входа, применение режима
/// и проверка фактического IP выхода. Прокси-сервисы приложение не настраивает —
/// только маршрутизирует их трафик через сервер-выход.
@MainActor
final class ProxiesViewModel: ObservableObject {
    /// Результат проверки фактического IP одного источника (хост или контейнер).
    struct EgressCheck: Identifiable, Equatable {
        let id: String
        let title: String
        let ip: String?
        let matches: Bool
    }

    @Published var enabled: Bool
    @Published private(set) var networks: [ProxyNetwork] = []
    @Published private(set) var amneziaNetworks: Set<String> = []
    /// Имена сетей, включённых пользователем (остальные исключены).
    @Published var selectedNetworks: Set<String> = []
    @Published private(set) var exitIP: String?
    @Published private(set) var egressChecks: [EgressCheck] = []
    @Published private(set) var loading = false
    @Published private(set) var applying = false
    @Published private(set) var checking = false
    @Published private(set) var message: String?
    @Published private(set) var errorText: String?

    private let store: ProfileStore

    init(store: ProfileStore) {
        self.store = store
        self.enabled = store.proxyEgressSettings.enabled
    }

    /// Сети, доступные для выбора: сеть AmneziaVPN исключена всегда.
    var availableNetworks: [ProxyNetwork] {
        networks.filter { !amneziaNetworks.contains($0.name) }
    }

    var isBusy: Bool { loading || applying || checking }

    var canApply: Bool { !isBusy }

    var canCheckEgress: Bool { !isBusy && exitIP != nil }

    /// Подпись кнопки применения: выключение — это тоже применение.
    var applyTitle: String {
        enabled ? "Применить правила" : "Выключить и снять правила"
    }

    // MARK: Действия

    /// Обновление списка сетей и публичного IP сервера-выхода.
    func refresh() {
        guard !isBusy else { return }
        loading = true
        message = nil
        errorText = nil
        let store = self.store
        Task {
            defer { loading = false }
            do {
                let connection = try await Self.connect(store: store)
                defer { Task { await connection.close() } }
                let environment = await Self.readEnvironment(on: connection.entry)
                let detection = try await ProxyNetworkDetector(runner: connection.entry)
                    .detect(
                        amneziaContainer: environment?.containerName,
                        amneziaBridge: environment?.bridge)
                let ip = try await ProxyNetworkDetector(runner: connection.exit).publicIP()
                let settings = store.proxyEgressSettings
                applyDetection(detection, exitIP: ip, settings: settings)
                message =
                    "Найдено сетей: \(detection.networks.count), публичный IP сервера-выхода: \(ip)"
            } catch {
                errorText = UserMessages.text(of: error)
            }
        }
    }

    /// Применение режима (включение или снятие правил) в порядке «выход → вход».
    func apply() {
        guard !isBusy else { return }
        applying = true
        message = nil
        errorText = nil
        egressChecks = []
        let store = self.store
        let desiredEnabled = enabled
        let selected = selectedNetworks
        Task {
            defer { applying = false }
            do {
                let connection = try await Self.connect(store: store)
                defer { Task { await connection.close() } }
                let environment = await Self.readEnvironment(on: connection.entry)
                // Свежий детект: bridge мог измениться после пересоздания сети.
                let detection = try await ProxyNetworkDetector(runner: connection.entry)
                    .detect(
                        amneziaContainer: environment?.containerName,
                        amneziaBridge: environment?.bridge)
                let known = Set(detection.networks.map(\.name))
                let excluded = detection.networks
                    .filter {
                        !detection.amneziaNetworks.contains($0.name) && !selected.contains($0.name)
                    }
                    .map(\.name)
                let settings = ProxyEgressSettings(
                    enabled: desiredEnabled,
                    excludedNetworks: excluded.filter { known.contains($0) }
                )

                let route = try await connection.exit.run(
                    ConfigureC2.wanDetectCommand, timeout: 30, onOutput: nil)
                guard let wan = ConfigureC2.parseDefaultInterface(route.stdout) else {
                    throw ProvisioningError.parseFailed(
                        "не удалось определить WAN-интерфейс сервера-выхода")
                }
                let ip = try await ProxyNetworkDetector(runner: connection.exit).publicIP()
                let engine = ProvisioningEngine(
                    c1: connection.entry,
                    c2: connection.exit,
                    input: try ProvisioningInput.fresh(s2Address: connection.exitProfile.host)
                )
                let applied = try await engine.applyProxyEgress(
                    settings: settings,
                    allNetworks: detection.networks,
                    amneziaNetworks: detection.amneziaNetworks,
                    exitIP: ip,
                    wanInterface: wan,
                    clientPort: environment?.clientPort
                )
                store.proxyEgressSettings = settings
                networks = detection.networks
                amneziaNetworks = detection.amneziaNetworks
                exitIP = ip
                message =
                    applied.enabled
                    ? "Правила применены: \(applied.networks.count) Docker-сет. через сервер-выход"
                    : "Режим выключен: правила, маршруты и NAT сняты на обоих серверах"
            } catch {
                errorText = UserMessages.text(of: error)
            }
        }
    }

    /// Проверка фактического IP: с сервера-входа и из каждого контейнера включённых сетей.
    func checkEgress() {
        guard !isBusy else { return }
        checking = true
        message = nil
        errorText = nil
        egressChecks = []
        let store = self.store
        let selected = selectedNetworks
        Task {
            defer { checking = false }
            do {
                let connection = try await Self.connect(store: store)
                defer { Task { await connection.close() } }
                let expected = try await ProxyNetworkDetector(runner: connection.exit).publicIP()
                exitIP = expected

                var checks: [EgressCheck] = []
                let namesResult = try? await connection.entry.run(
                    EnvironmentDetector.listContainersCommand, timeout: 30, onOutput: nil)
                let names =
                    namesResult.map {
                        EnvironmentDetector.parseContainerNames($0.stdout)
                    } ?? []
                for name in names {
                    guard
                        let networksResult = try? await connection.entry.run(
                            ProxyNetworkDetector.containerNetworkNamesCommand(container: name),
                            timeout: 30, onOutput: nil)
                    else { continue }
                    let containerNetworks = Set(
                        ProxyNetworkDetector.parseContainerNetworkNames(networksResult.stdout))
                    // Только реально выбранные сети: иначе проверка показывала бы
                    // контейнеры, трафик которых режим не маркирует.
                    guard !containerNetworks.isDisjoint(with: selected) else { continue }
                    let result = try? await connection.entry.run(
                        ProxyNetworkDetector.containerEgressCommand(container: name), timeout: 30,
                        onOutput: nil)
                    let ip = ProxyNetworkDetector.parsePublicIP(result?.stdout ?? "")
                    checks.append(
                        EgressCheck(
                            id: "container-\(name)",
                            title: "Контейнер \(name)",
                            ip: ip,
                            matches: ip == expected
                        ))
                }
                egressChecks = checks
                message =
                    checks.isEmpty
                    ? (selected.isEmpty
                        ? "Сети не выбраны — сначала отметьте сети и примените правила"
                        : "Нет контейнеров в выбранных сетях — проверять нечего")
                    : checks.allSatisfy(\.matches)
                        ? "Все контейнеры выходят через сервер-выход"
                        : "Часть контейнеров выходит не через сервер-выход (или без curl/wget внутри)"
            } catch {
                errorText = UserMessages.text(of: error)
            }
        }
    }

    // MARK: Внутреннее

    private func applyDetection(
        _ detection: ProxyNetworkDetection,
        exitIP: String,
        settings: ProxyEgressSettings
    ) {
        networks = detection.networks
        amneziaNetworks = detection.amneziaNetworks
        self.exitIP = exitIP
        selectedNetworks = Set(
            detection.networks
                .filter {
                    !detection.amneziaNetworks.contains($0.name)
                        && !settings.excludedNetworks.contains($0.name)
                }
                .map(\.name))
    }

    private struct ServerConnection: Sendable {
        let entry: SSHClient
        let exit: SSHClient
        let exitProfile: ConnectionProfile

        func close() async {
            await entry.close()
            await exit.close()
        }
    }

    private static func connect(store: ProfileStore) async throws -> ServerConnection {
        let checker = ConnectionChecker(store: store) { host, fingerprint in
            await ConnectionsViewModel.confirmFingerprint(host: host, fingerprint: fingerprint)
        }
        guard let entry = store.profile(for: .entry), let exit = store.profile(for: .exit) else {
            throw ConnectionChecker.CheckError.profileInvalid(
                "настройте оба подключения во вкладке «Подключения»")
        }
        let c1 = SSHClient(options: try checker.connectOptions(for: entry))
        let c2 = SSHClient(options: try checker.connectOptions(for: exit))
        do {
            try await c1.connect()
            try await c2.connect()
        } catch {
            await c1.close()
            throw error
        }
        return ServerConnection(entry: c1, exit: c2, exitProfile: exit)
    }

    private static func readEnvironment(on runner: any RemoteRunner) async
        -> ChainState.Environment?
    {
        guard
            let result = try? await runner.run(
                StatusParsers.environmentCommand, timeout: 30, onOutput: nil),
            result.succeeded || !result.stdout.isEmpty
        else {
            return nil
        }
        return try? ChainStateParser.parseEnvironment(result.stdout)
    }
}
