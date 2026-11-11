import SwiftUI
import VPNChainCore

/// Экран «Диагностика» (задача 6.5): выбор симптома → автоматические проверки
/// с подсказками + советы по разделу 11 ТЗ; uninstall по ролям.
struct DiagnosticsView: View {
    @StateObject private var viewModel: DiagnosticsViewModel
    @State private var confirmUninstallRole: ServerRole?

    init(store: ProfileStore = AppServices.shared.profiles) {
        _viewModel = StateObject(wrappedValue: DiagnosticsViewModel(store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                symptomCard
                if let guide = viewModel.guide {
                    guideResultsCard(guide)
                    adviceCard(guide)
                }
                uninstallCard
                if let report = viewModel.uninstallReport {
                    Text(report)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                if let error = viewModel.errorText {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Диагностика")
    }

    // MARK: Симптом

    private var symptomCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Симптом", selection: $viewModel.selectedSymptom) {
                    ForEach(Symptom.allCases, id: \.self) { symptom in
                        Text(Self.symptomTitle(symptom)).tag(symptom)
                    }
                }
                .labelsHidden()

                Button {
                    viewModel.diagnose()
                } label: {
                    if viewModel.diagnosing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Диагностирую…")
                        }
                    } else {
                        Text("Диагностировать")
                    }
                }
                .disabled(viewModel.diagnosing)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Результаты проверок

    @ViewBuilder
    private func guideResultsCard(_ guide: SymptomGuide) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Проверки").font(.headline)
                if guide.checks.isEmpty, !viewModel.diagnosing {
                    Text("Для этого симптома автоматических проверок нет — следуйте советам ниже.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    // MARK: Советы

    private func adviceCard(_ guide: SymptomGuide) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Что делать").font(.headline)
                Text(guide.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(Array(guide.advice.enumerated()), id: \.offset) { _, advice in
                    Text(advice)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if guide.suggestsReapply {
                    Label("Перейдите во вкладку «Установка» и запустите её заново — движок обновит конфигурацию сервера-выхода.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Uninstall

    private var uninstallCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Очистка серверов (uninstall)").font(.headline)
                Text("Удаляются только артефакты с маркером amnezia-chain: юниты, правила, конфиги, /etc/amnezia/chain, persist-файл. Контейнер AmneziaVPN и SSH-доступ не затрагиваются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Также удалить собранное ПО (awg, awg-quick, amneziawg-go)", isOn: bindingForSoftwareToggle)
                    .font(.callout)

                HStack(spacing: 10) {
                    Button("Очистить сервер-вход") {
                        confirmUninstallRole = .entry
                    }
                    .disabled(viewModel.uninstalling != nil)
                    Button("Очистить сервер-выход") {
                        confirmUninstallRole = .exit
                    }
                    .disabled(viewModel.uninstalling != nil)
                    if viewModel.uninstalling != nil {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Удалить все артефакты цепочки с \(confirmUninstallRole == .entry ? "сервера-входа" : "сервера-выхода")?",
            isPresented: Binding(
                get: { confirmUninstallRole != nil },
                set: { if !$0 { confirmUninstallRole = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let role = confirmUninstallRole {
                    viewModel.uninstall(role, alsoSoftware: alsoRemoveSoftware)
                }
                confirmUninstallRole = nil
            }
            Button("Отмена", role: .cancel) {
                confirmUninstallRole = nil
            }
        } message: {
            Text("Будут удалены юниты, правила, конфиги awg-relay и состояние /etc/amnezia/chain. Контейнер AmneziaVPN и SSH останутся рабочими.")
        }
    }

    @State private var alsoRemoveSoftware = false
    private var bindingForSoftwareToggle: Binding<Bool> {
        Binding(get: { alsoRemoveSoftware }, set: { alsoRemoveSoftware = $0 })
    }

    private static func symptomTitle(_ symptom: Symptom) -> String {
        switch symptom {
        case .noHandshake: "Нет handshake между серверами"
        case .handshakeButNoInternet: "Handshake есть, интернета нет"
        case .brokenAfterAppUserAdded: "Сломалось после добавления пользователя в приложении"
        case .dockerNetworkRecreated: "Docker-сеть пересоздана"
        case .sshLost: "Пропал SSH на сервере-входе"
        case .slowSpeed: "Работает, но медленно"
        case .ipv6Leak: "IPv6-утечка у клиента"
        }
    }
}
