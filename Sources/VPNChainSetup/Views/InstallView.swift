import SwiftUI
import VPNChainCore

/// Экран «Установка» (задача 5.5): шаги FSM со статусами, живой вывод,
/// итоговая сводка с подсказкой про UDP 51828 у провайдера.
struct InstallView: View {
    @StateObject private var viewModel: InstallViewModel

    init(store: ProfileStore = AppServices.shared.profiles) {
        _viewModel = StateObject(wrappedValue: InstallViewModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            stepsList
            if let summary = viewModel.summary {
                summaryBox(summary)
            }
            if let error = viewModel.errorText {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            logPane
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Установка")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let entry = AppServices.shared.profiles.profile(for: .entry) {
                    Label("Сервер-вход: \(entry.host)\(entry.port == 22 ? "" : ":\(entry.port)")", systemImage: "arrow.right.to.line")
                        .font(.callout)
                        .foregroundStyle(.blue)
                }
                if let exit = AppServices.shared.profiles.profile(for: .exit) {
                    Label("Сервер-выход: \(exit.host)\(exit.port == 22 ? "" : ":\(exit.port)")", systemImage: "globe")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                if let hint = viewModel.readinessHint {
                    Text(hint).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(viewModel.running ? "Идёт установка…" : "Начать установку") {
                viewModel.start()
            }
            .disabled(!viewModel.canStart)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    stepIcon(state: step.state)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.body)
                        if let detail = step.detail, step.state == .done || step.state == .failed || step.state == .skipped {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if step.state == .running {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func stepIcon(state: StepProgress.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private func summaryBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Сводка", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(12)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var logPane: some View {
        GroupBox("Вывод команд") {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(viewModel.logLines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                        .id("logBottom")
                }
                .frame(minHeight: 160, maxHeight: 260)
                .onChange(of: viewModel.logLines.count) { _ in
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}
