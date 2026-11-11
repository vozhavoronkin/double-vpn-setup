import SwiftUI
import VPNChainCore

/// Экран «Статус» (задача 6.5): снапшот цепочки, автоматические проверки
/// раздела 10 ТЗ и ручной чек-лист.
struct StatusView: View {
    @StateObject private var viewModel: StatusViewModel

    init(store: ProfileStore = AppServices.shared.profiles) {
        _viewModel = StateObject(wrappedValue: StatusViewModel(store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button("Обновить") {
                        viewModel.refresh()
                    }
                    .disabled(viewModel.refreshing)
                    if viewModel.refreshing {
                        ProgressView().controlSize(.small)
                    }
                }

                if let error = viewModel.errorText {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: 560, alignment: .leading)
                }

                entryCard
                exitCard
                checksCard
                manualCard
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Статус")
        .onAppear {
            viewModel.refresh()
        }
    }

    // MARK: Карточка сервера-входа

    @ViewBuilder
    private var entryCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Сервер-вход", systemImage: "arrow.right.to.line")
                    .font(.headline)
                    .foregroundStyle(.blue)
                switch viewModel.snapshot?.entry {
                case .unreachable(let reason):
                    Text("Нет связи: \(reason)")
                        .foregroundStyle(.secondary)
                case .available(let status):
                    statusRow("Интерфейс awg-relay", value: status.relay?.interfaceUp)
                    if let seconds = status.relay?.handshakeSecondsAgo {
                        plainRow("Handshake", value: Self.handshakeText(seconds), ok: seconds <= 180)
                    } else {
                        plainRow("Handshake", value: "не зафиксирован", ok: false)
                    }
                    if let rx = status.relay?.rxBytes, let tx = status.relay?.txBytes {
                        plainRow("Трафик", value: "получено \(Self.bytes(rx)), отправлено \(Self.bytes(tx))", ok: true)
                    }
                    statusRow("Policy routing (таблица 51821)", value: status.policyRulePresent)
                    if let route = status.routeKillSwitch {
                        plainRow("Kill-switch", value: route.defaultViaRelay && route.blackhole ? "активен" : "отсутствует", ok: route.defaultViaRelay && route.blackhole)
                    }
                    statusRow("Цепочка VPNCHAIN в DOCKER-USER", value: status.dockerUserJump)
                    if let container = status.containerAlive {
                        statusRow("Контейнер AmneziaVPN", value: container)
                    }
                case nil:
                    Text("Нажмите «Обновить»").foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Карточка сервера-выхода

    @ViewBuilder
    private var exitCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Сервер-выход", systemImage: "globe")
                    .font(.headline)
                    .foregroundStyle(.green)
                switch viewModel.snapshot?.exit {
                case .unreachable(let reason):
                    Text("Нет связи: \(reason)")
                        .foregroundStyle(.secondary)
                case .available(let status):
                    statusRow("Интерфейс awg-relay", value: status.relay?.interfaceUp)
                    if let seconds = status.relay?.handshakeSecondsAgo {
                        plainRow("Handshake", value: Self.handshakeText(seconds), ok: seconds <= 180)
                    } else {
                        plainRow("Handshake", value: "не зафиксирован", ok: false)
                    }
                    statusRow("Порт 51828/UDP слушается", value: status.portListening)
                    statusRow("MASQUERADE по Docker-подсети", value: status.masqueradeForDockerSubnet)
                case nil:
                    Text("Нажмите «Обновить»").foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Автоматические проверки

    @ViewBuilder
    private var checksCard: some View {
        if !viewModel.checkResults.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Проверки (раздел 10 ТЗ)").font(.headline)
                    ForEach(viewModel.checkResults) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(result.title, systemImage: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.passed ? .green : .red)
                            if let hint = result.hint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Ручной чек-лист

    private var manualCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ручной чек-лист").font(.headline)
                Text("Эти пункты требуют клиента или перезагрузки серверов — выполняются вручную:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ManualChecklist.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout)
                        Text(item.instruction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Хелперы

    @ViewBuilder
    private func statusRow(_ title: String, value: Bool?) -> some View {
        if let value {
            plainRow(title, value: value ? "ок" : "не на месте", ok: value)
        }
    }

    private func plainRow(_ title: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    static func handshakeText(_ seconds: Int) -> String {
        "\(seconds) c назад"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}
