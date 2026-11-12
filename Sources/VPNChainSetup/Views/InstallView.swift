import SwiftUI
import VPNChainCore

/// Экран «Установка» (задача 5.5): шаги FSM со статусами, живой вывод,
/// итоговая сводка с подсказкой про UDP 51828 у провайдера.
struct InstallView: View {
    @StateObject private var viewModel: InstallViewModel
    @ObservedObject private var router = AppServices.shared.commands

    init(store: ProfileStore = AppServices.shared.profiles) {
        _viewModel = StateObject(wrappedValue: InstallViewModel(store: store))
    }

    var body: some View {
        PageScaffold {
            headerCard
            stepsCard
            if let summary = viewModel.summary {
                summaryCard(summary)
            }
            if let error = viewModel.errorText {
                Banner(kind: .error, text: error)
            }
            logCard
        }
        .navigationTitle("Установка")
        .onAppear(perform: consumeCommand)
        .onChange(of: router.pendingToken) { _ in
            consumeCommand()
        }
    }

    /// Команда меню «Начать установку» (⌘↩).
    private func consumeCommand() {
        guard router.pending == .startInstall else { return }
        router.consume(.startInstall)
        viewModel.start()
    }

    // MARK: Шапка

    private var headerCard: some View {
        Card(
            title: "Развёртывание цепочки",
            systemImage: "arrow.down.circle",
            subtitle: "Порядок шагов: сначала сервер-выход, затем сервер-вход и проверка handshake",
            accessory: {
                if viewModel.running {
                    StatusPill(kind: .progress, text: "Идёт установка")
                }
            }
        ) {
            HStack(alignment: .center, spacing: 10) {
                serverChip(.entry)
                serverChip(.exit)
                Spacer(minLength: 8)
                Button(viewModel.running ? "Идёт установка…" : "Начать установку") {
                    viewModel.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)
                .keyboardShortcut(.defaultAction)
                .help("Начать установку (⌘↩)")
            }
            if let hint = viewModel.readinessHint {
                Banner(kind: .info, text: hint)
            }
        }
    }

    private func serverChip(_ role: ServerRole) -> some View {
        let profile = AppServices.shared.profiles.profile(for: role)
        let address = profile.map { "\($0.host)\($0.port == 22 ? "" : ":\($0.port)")" }
        return HStack(spacing: 8) {
            Image(systemName: role == .entry ? "arrow.right.to.line" : "globe")
                .foregroundStyle(role == .entry ? .blue : .green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(role == .entry ? "Сервер-вход" : "Сервер-выход")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(address ?? "не настроен")
                    .font(.callout)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Шаги

    private var stepsCard: some View {
        Card(
            title: "Шаги установки",
            systemImage: "list.number",
            accessory: {
                StatusPill(kind: stepsKind, text: viewModel.progressTitle)
            }
        ) {
            ProgressView(value: viewModel.progressFraction)
                .progressViewStyle(.linear)
                .accessibilityLabel("Прогресс установки")
                .accessibilityValue(viewModel.progressTitle)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.steps.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, isLast: index == viewModel.steps.count - 1)
                }
            }
            .padding(.top, 4)
        }
    }

    private var stepsKind: StatusKind {
        if viewModel.running { return .progress }
        if viewModel.steps.contains(where: { $0.state == .failed }) { return .error }
        if viewModel.completedCount == viewModel.steps.count, !viewModel.steps.isEmpty { return .ok }
        return .neutral
    }

    private func stepRow(_ step: InstallViewModel.StepRow, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                stepIcon(state: step.state)
                    .frame(width: 20, height: 20)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 2)
                    .opacity(isLast ? 0 : 1)
                    .accessibilityHidden(true)
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.callout)
                    .foregroundStyle(step.state == .pending ? .secondary : .primary)
                if let detail = step.detail,
                   step.state == .done || step.state == .failed || step.state == .skipped {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 12)

            Spacer(minLength: 8)
            if step.state == .running {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stepIcon(state: StepProgress.State) -> some View {
        let kind: StatusKind = switch state {
        case .pending: .neutral
        case .running: .progress
        case .done: .ok
        case .failed: .error
        case .skipped: .neutral
        }
        let symbol = switch state {
        case .pending: "circle.dashed"
        case .running: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
        return Image(systemName: symbol)
            .font(.callout)
            .foregroundStyle(kind.tint)
    }

    // MARK: Сводка и журнал

    private func summaryCard(_ text: String) -> some View {
        Card(title: "Сводка", systemImage: "checkmark.seal.fill", tint: .green) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var logCard: some View {
        Card(
            title: "Вывод команд",
            systemImage: "terminal",
            accessory: {
                Button("Скопировать") {
                    viewModel.copyLogToPasteboard()
                }
                .disabled(viewModel.logLines.isEmpty)
                .help("Скопировать журнал в буфер обмена")
            }
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if viewModel.logLines.isEmpty {
                            Text("Вывод появится после запуска установки")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(viewModel.logLines.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                    .id("logBottom")
                }
                .frame(minHeight: 160, maxHeight: 260)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .onChange(of: viewModel.logLines.count) { _ in
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
    }
}
