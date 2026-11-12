import SwiftUI
import VPNChainCore

/// Экран «Статус» (задача 6.5): вердикт по цепочке, схема звеньев, метрики серверов
/// и автоматические проверки раздела 10 ТЗ.
struct StatusView: View {
    @StateObject private var viewModel: StatusViewModel
    @ObservedObject private var router = AppServices.shared.commands
    @State private var manualChecklistExpanded = false

    init(store: ProfileStore = AppServices.shared.profiles) {
        _viewModel = StateObject(wrappedValue: StatusViewModel(store: store))
    }

    var body: some View {
        PageScaffold {
            if let error = viewModel.errorText {
                Banner(kind: .error, text: error)
            }
            if viewModel.snapshot == nil {
                placeholderState
            } else {
                heroCard
                serverCards
                checksCard
                manualCard
            }
        }
        .navigationTitle("Статус")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.refresh()
                } label: {
                    Label("Обновить статус", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .disabled(viewModel.refreshing)
                .help("Обновить статус (⌘R)")
            }
        }
        .onAppear {
            consumeCommand()
            viewModel.refresh()
        }
        .onChange(of: router.pendingToken) { _ in
            consumeCommand()
        }
    }

    /// Команда меню «Обновить статус» (⌘R).
    private func consumeCommand() {
        guard router.pending == .refreshStatus else { return }
        router.consume(.refreshStatus)
        viewModel.refresh()
    }

    // MARK: Пока статус не получен

    @ViewBuilder
    private var placeholderState: some View {
        if viewModel.refreshing {
            Card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Проверяю цепочку…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Card {
                EmptyState(
                    systemImage: "gauge.with.dots.needle.67percent",
                    title: "Статус не проверялся",
                    message: "Обновите статус, чтобы увидеть состояние звеньев, метрики серверов и результаты проверок."
                ) {
                    Button("Проверить цепочку") {
                        viewModel.refresh()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: Общее состояние

    private var healthKind: StatusKind {
        switch viewModel.overallHealth {
        case .notChecked: .neutral
        case .ok: .ok
        case .attention: .warning
        case .offline: .error
        }
    }

    private var healthSymbol: String {
        switch viewModel.overallHealth {
        case .notChecked: "questionmark.circle"
        case .ok: "checkmark.shield.fill"
        case .attention: "exclamationmark.shield.fill"
        case .offline: "xmark.shield.fill"
        }
    }

    private var heroCard: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemImage: healthSymbol, tint: healthKind.tint, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.overallHealth.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(updatedDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if viewModel.refreshing {
                    ProgressView().controlSize(.small)
                }
                Button("Обновить") {
                    viewModel.refresh()
                }
                .disabled(viewModel.refreshing)
            }
            ChainDiagram(
                entry: entryLinkState,
                exit: exitLinkState
            )
            .padding(.top, 6)
        }
    }

    private var updatedDetail: String {
        var text = viewModel.overallHealth.detail
        if let updated = viewModel.lastUpdatedAt {
            text += " · обновлено \(Self.timeFormatter.string(from: updated))"
        }
        return text
    }

    private var entryLinkState: ChainDiagram.LinkState {
        guard let entry = viewModel.snapshot?.entry else { return .neutral }
        switch entry {
        case .unreachable:
            return .error
        case .available(let status):
            return status.relay?.interfaceUp == true ? .ok : .error
        }
    }

    private var exitLinkState: ChainDiagram.LinkState {
        guard let exit = viewModel.snapshot?.exit else { return .neutral }
        switch exit {
        case .unreachable:
            return .error
        case .available(let status):
            let relayUp = status.relay?.interfaceUp == true
            let portOpen = status.portListening == true
            return relayUp && portOpen ? .ok : (relayUp ? .warning : .error)
        }
    }

    private var internetLinkState: ChainDiagram.LinkState {
        if viewModel.errorText != nil { return .neutral }
        if viewModel.failedCount > 0 { return .warning }
        return viewModel.overallHealth == .ok ? .ok : .neutral
    }

    // MARK: Карточки серверов

    private var serverCards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320), spacing: AppTheme.sectionSpacing)],
            alignment: .leading,
            spacing: AppTheme.sectionSpacing
        ) {
            entryCard
            exitCard
        }
    }

    @ViewBuilder
    private var entryCard: some View {
        Card(
            title: "Сервер-вход",
            systemImage: "arrow.right.to.line",
            subtitle: viewModel.entryHost,
            tint: .blue,
            accessory: { serverPill(viewModel.snapshot?.entry) }
        ) {
            switch viewModel.snapshot?.entry {
            case .unreachable(let reason):
                Banner(kind: .warning, text: "Нет связи: \(reason)")
            case .available(let status):
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("Интерфейс awg-relay", value: status.relay?.interfaceUp)
                    if let seconds = status.relay?.handshakeSecondsAgo {
                        MetricRow(
                            title: "Handshake",
                            value: Self.handshakeText(seconds),
                            state: seconds <= 180 ? .ok : .warning
                        )
                    } else {
                        MetricRow(title: "Handshake", value: "не зафиксирован", state: .error)
                    }
                    if let rx = status.relay?.rxBytes, let tx = status.relay?.txBytes {
                        MetricRow(
                            title: "Трафик",
                            value: "получено \(Self.bytes(rx)), отправлено \(Self.bytes(tx))",
                            state: .neutral
                        )
                    }
                    statusRow("Policy routing (таблица 51821)", value: status.policyRulePresent)
                    if let route = status.routeKillSwitch {
                        MetricRow(
                            title: "Kill-switch",
                            value: route.defaultViaRelay && route.blackhole ? "активен" : "отсутствует",
                            state: route.defaultViaRelay && route.blackhole ? .ok : .error
                        )
                    }
                    statusRow("Цепочка VPNCHAIN в DOCKER-USER", value: status.dockerUserJump)
                    if let container = status.containerAlive {
                        statusRow("Контейнер AmneziaVPN", value: container)
                    }
                }
            case nil:
                Text("Нажмите «Обновить»").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var exitCard: some View {
        Card(
            title: "Сервер-выход",
            systemImage: "globe",
            subtitle: viewModel.exitHost,
            tint: .green,
            accessory: { serverPill(viewModel.snapshot?.exit) }
        ) {
            switch viewModel.snapshot?.exit {
            case .unreachable(let reason):
                Banner(kind: .warning, text: "Нет связи: \(reason)")
            case .available(let status):
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("Интерфейс awg-relay", value: status.relay?.interfaceUp)
                    if let seconds = status.relay?.handshakeSecondsAgo {
                        MetricRow(
                            title: "Handshake",
                            value: Self.handshakeText(seconds),
                            state: seconds <= 180 ? .ok : .warning
                        )
                    } else {
                        MetricRow(title: "Handshake", value: "не зафиксирован", state: .error)
                    }
                    statusRow("Порт 51828/UDP слушается", value: status.portListening)
                    statusRow("MASQUERADE по Docker-подсети", value: status.masqueradeForDockerSubnet)
                }
            case nil:
                Text("Нажмите «Обновить»").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func serverPill<T: Sendable>(_ availability: ServerAvailability<T>?) -> some View {
        switch availability {
        case .unreachable:
            StatusPill(kind: .error, text: "Нет связи")
        case .available:
            StatusPill(kind: .ok, text: "Доступен")
        case nil:
            StatusPill(kind: .neutral, text: "Не проверен")
        }
    }

    // MARK: Проверки

    @ViewBuilder
    private var checksCard: some View {
        if !viewModel.checkResults.isEmpty {
            Card(
                title: "Проверки",
                systemImage: "checklist",
                subtitle: "Раздел 10 ТЗ",
                accessory: {
                    StatusPill(
                        kind: viewModel.failedCount == 0 ? .ok : .warning,
                        text: "\(viewModel.passedCount) из \(viewModel.checkResults.count)"
                    )
                }
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.checkResults) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Label {
                                Text(result.title).font(.callout)
                            } icon: {
                                Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.passed ? .green : .red)
                            }
                            if let hint = result.hint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 22)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var manualCard: some View {
        Card {
            DisclosureGroup("Ручной чек-лист", isExpanded: $manualChecklistExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Эти пункты требуют клиента или перезагрузки серверов — выполняются вручную:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    // MARK: Хелперы

    @ViewBuilder
    private func statusRow(_ title: String, value: Bool?) -> some View {
        if let value {
            MetricRow(title: title, value: value ? "ок" : "не на месте", state: value ? .ok : .error)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func handshakeText(_ seconds: Int) -> String {
        "\(seconds) c назад"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}

// MARK: - Схема звеньев

/// Горизонтальная схема «Клиент → Сервер-вход → Сервер-выход → Интернет»:
/// каждое звено окрашено по своему состоянию и читается VoiceOver по отдельности.
struct ChainDiagram: View {
    enum LinkState {
        case ok
        case warning
        case error
        case neutral

        var kind: StatusKind {
            switch self {
            case .ok: .ok
            case .warning: .warning
            case .error: .error
            case .neutral: .neutral
            }
        }

        var caption: String {
            switch self {
            case .ok: "активен"
            case .warning: "внимание"
            case .error: "ошибка"
            case .neutral: "не проверен"
            }
        }
    }

    let entry: LinkState
    let exit: LinkState

    private var internet: LinkState {
        switch (entry, exit) {
        case (.ok, .ok): .ok
        case (.error, _), (_, .error): .neutral
        default: .warning
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            node(title: "Клиент", systemImage: "laptopcomputer", state: .neutral)
            connector
            node(title: "Сервер-вход", systemImage: "arrow.right.to.line", state: entry)
            connector
            node(title: "Сервер-выход", systemImage: "globe", state: exit)
            connector
            node(title: "Интернет", systemImage: "network", state: internet)
        }
        .accessibilityElement(children: .contain)
    }

    private func node(title: String, systemImage: String, state: LinkState) -> some View {
        VStack(spacing: 6) {
            IconBadge(systemImage: systemImage, tint: state.kind.tint, size: 32)
            VStack(spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                Text(state.caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(state.caption)")
    }

    private var connector: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: 26)
            .padding(.top, 16)
            .accessibilityHidden(true)
    }
}
