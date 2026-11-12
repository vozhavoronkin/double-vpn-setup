import SwiftUI
import VPNChainCore

/// Экран «Прокси»: включение режима направления исходящего трафика сервера-входа
/// через сервер-выход, выбор Docker-сетей и проверка фактического IP выхода.
struct ProxiesView: View {
    @StateObject private var viewModel: ProxiesViewModel

    init(store: ProfileStore = AppServices.shared.profiles) {
        _viewModel = StateObject(wrappedValue: ProxiesViewModel(store: store))
    }

    var body: some View {
        PageScaffold {
            modeCard
            if let message = viewModel.message {
                Banner(kind: .success, text: message)
            }
            if let error = viewModel.errorText {
                Banner(kind: .error, text: error)
            }
            networksCard
            egressCard
            responsibilityCard
        }
        .navigationTitle("Прокси")
        .onAppear {
            if viewModel.networks.isEmpty {
                viewModel.refresh()
            }
        }
    }

    // MARK: Режим

    private var modeCard: some View {
        Card(
            title: "Режим проксирования",
            systemImage: "arrow.triangle.branch",
            subtitle: "Опция выключена по умолчанию — без неё поведение цепочки не меняется",
            accessory: {
                StatusPill(
                    kind: viewModel.enabled ? .ok : .neutral,
                    text: viewModel.enabled ? "включён" : "выключен")
            }
        ) {
            Toggle(
                "Направлять трафик дополнительных прокси через сервер-выход",
                isOn: $viewModel.enabled
            )
            .toggleStyle(.switch)

            Text(
                "Режим затрагивает весь исходящий трафик сервера-входа: обновления пакетов, docker pull и DNS тоже пойдут через сервер-выход. Клиенты дополнительных прокси увидят IP выхода."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    viewModel.refresh()
                } label: {
                    if viewModel.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Обновить список сетей")
                    }
                }
                .disabled(viewModel.isBusy)
                .help("Перечитать Docker-сети сервера-входа и публичный IP сервера-выхода")

                Spacer(minLength: 0)

                Button(viewModel.applyTitle) {
                    viewModel.apply()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canApply)
                .help("Применить правила: сначала сервер-выход, затем сервер-вход")

                Button {
                    viewModel.checkEgress()
                } label: {
                    if viewModel.checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Проверить выход")
                    }
                }
                .disabled(!viewModel.canCheckEgress)
                .help(
                    "Сравнить фактический IP с сервера-входа и из контейнеров с IP сервера-выхода")
            }
        }
    }

    // MARK: Сети

    private var networksCard: some View {
        Card(
            title: "Docker-сети",
            systemImage: "shippingbox",
            subtitle:
                "Отмеченные сети маршрутизируются через сервер-выход; новый контейнер в них подхватится автоматически"
        ) {
            if viewModel.networks.isEmpty {
                EmptyState(
                    systemImage: "network.slash",
                    title: "Сети не обнаружены",
                    message:
                        "Нажмите «Обновить список сетей», чтобы прочитать Docker-сети сервера-входа. Если режим включён без списка, через сервер-выход пойдёт только хостовый трафик."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.networks) { network in
                        if viewModel.amneziaNetworks.contains(network.name) {
                            networkRow(network, alwaysExcluded: true)
                        } else {
                            networkRow(network, alwaysExcluded: false)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkRow(_ network: ProxyNetwork, alwaysExcluded: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(
                isOn: alwaysExcluded
                    ? .constant(false) : selectionBinding(for: network)
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(network.name)
                        .font(.callout)
                    Text("\(network.subnet) · \(network.bridge)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(alwaysExcluded)
            .accessibilityLabel(
                alwaysExcluded
                    ? "Сеть \(network.name), всегда исключена"
                    : "Сеть \(network.name)")
            if alwaysExcluded {
                Text("сеть AmneziaVPN — исключена всегда")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func selectionBinding(for network: ProxyNetwork) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedNetworks.contains(network.name) },
            set: { isOn in
                if isOn {
                    viewModel.selectedNetworks.insert(network.name)
                } else {
                    viewModel.selectedNetworks.remove(network.name)
                }
            }
        )
    }

    // MARK: Проверка выхода

    private var egressCard: some View {
        Card(
            title: "Фактический выход",
            systemImage: "location.magnifyingglass",
            subtitle: viewModel.exitIP.map { "Публичный IP сервера-выхода: \($0)" }
                ?? "Нажмите «Обновить список сетей», чтобы узнать IP сервера-выхода"
        ) {
            if viewModel.egressChecks.isEmpty {
                Text(
                    "«Проверить выход» сравнивает IP с сервера-входа и из каждого контейнера включённых сетей с публичным IP сервера-выхода."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: AppTheme.rowSpacing) {
                    ForEach(viewModel.egressChecks) { check in
                        MetricRow(
                            title: check.title,
                            value: check.ip ?? "нет ответа",
                            state: check.matches ? .ok : .error
                        )
                    }
                }
            }
        }
    }

    // MARK: Предупреждение

    private var responsibilityCard: some View {
        Card(
            title: "Важно",
            systemImage: "exclamationmark.shield",
            subtitle:
                "Приложение только маршрутизирует трафик — прокси-сервисы настраиваются отдельно",
            tint: .orange
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Аутентификация, пароли и firewall на прокси — ответственность пользователя. Приложение не устанавливает и не настраивает прокси-сервисы."
                )
                Text(
                    "Туннель IPv4-only: при включённом режиме исходящий IPv6 с сервера-входа и из включённых контейнеров блокируется, чтобы трафик не ушёл мимо сервера-выхода."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }
}
