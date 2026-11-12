import SwiftUI
import VPNChainCore

/// Экран «Диагностика» (задача 6.5): выбор симптома → автоматические проверки
/// с подсказками + советы по разделу 11 ТЗ; uninstall по ролям в отдельной «опасной» карточке.
struct DiagnosticsView: View {
    @StateObject private var viewModel: DiagnosticsViewModel
    @ObservedObject private var router = AppServices.shared.commands
    @State private var confirmUninstallRole: ServerRole?
    @State private var alsoRemoveSoftware = false

    init(store: ProfileStore = AppServices.shared.profiles) {
        _viewModel = StateObject(wrappedValue: DiagnosticsViewModel(store: store))
    }

    var body: some View {
        PageScaffold {
            symptomCard
            if let error = viewModel.errorText {
                Banner(kind: .error, text: error)
            }
            if let guide = viewModel.guide {
                resultsCard(guide)
                adviceCard(guide)
            }
            if let report = viewModel.uninstallReport {
                Banner(kind: uninstallBannerKind, text: report)
            }
            uninstallCard
        }
        .navigationTitle("Диагностика")
        .onAppear(perform: consumeCommand)
        .onChange(of: router.pendingToken) { _ in
            consumeCommand()
        }
    }

    /// Команда меню «Диагностировать» (⌘D).
    private func consumeCommand() {
        guard router.pending == .runDiagnostics else { return }
        router.consume(.runDiagnostics)
        viewModel.diagnose()
    }

    /// Отчёт об очистке: частичное выполнение показываем предупреждением, а не успехом.
    private var uninstallBannerKind: Banner.Kind {
        guard let report = viewModel.uninstallReport else { return .info }
        return report.contains("частично") || report.contains("не удалось") ? .warning : .success
    }

    // MARK: Симптом

    private var symptomCard: some View {
        Card(
            title: "Диагностика по симптому",
            systemImage: "stethoscope",
            subtitle:
                "Выберите, что происходит, — приложение выполнит доступные проверки на серверах"
        ) {
            LabeledField("Симптом") {
                Picker("Симптом", selection: $viewModel.selectedSymptom) {
                    ForEach(Symptom.allCases, id: \.self) { symptom in
                        Text(Self.symptomTitle(symptom)).tag(symptom)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer(minLength: 0)
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
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.diagnosing)
                .keyboardShortcut(.defaultAction)
                .help("Запустить диагностику (⌘D)")
            }
        }
    }

    // MARK: Результаты проверок

    private func resultsCard(_ guide: SymptomGuide) -> some View {
        Card(
            title: "Проверки",
            systemImage: "checklist",
            accessory: {
                if viewModel.totalCount > 0 {
                    StatusPill(
                        kind: viewModel.passedCount == viewModel.totalCount ? .ok : .warning,
                        text: "\(viewModel.passedCount) из \(viewModel.totalCount)"
                    )
                } else if viewModel.diagnosing {
                    StatusPill(kind: .progress, text: "Выполняю")
                }
            }
        ) {
            if guide.checks.isEmpty, !viewModel.diagnosing {
                Text("Для этого симптома автоматических проверок нет — следуйте советам ниже.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.checkResults) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(result.title).font(.callout)
                        } icon: {
                            Image(
                                systemName: result.passed
                                    ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
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

    // MARK: Советы

    private func adviceCard(_ guide: SymptomGuide) -> some View {
        Card(title: "Что делать", systemImage: "lightbulb") {
            Text(guide.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(guide.advice.enumerated()), id: \.offset) { index, advice in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18, height: 18)
                            .background(Color.accentColor.opacity(0.15), in: Circle())
                            .accessibilityLabel("Шаг \(index + 1)")
                        Text(advice)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if guide.suggestsReapply {
                Banner(
                    kind: .warning,
                    text:
                        "Перейдите в раздел «Установка» и запустите её заново — движок обновит конфигурацию сервера-выхода."
                )
            }
        }
    }

    // MARK: Очистка серверов

    private var uninstallCard: some View {
        Card(
            title: "Очистка серверов",
            systemImage: "trash",
            subtitle:
                "Удаляются только артефакты с маркером amnezia-chain: юниты, правила, конфиги, /etc/amnezia/chain, persist-файл.",
            tint: .red
        ) {
            Text("Контейнер AmneziaVPN и SSH-доступ не затрагиваются.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Также удалить собранное ПО (awg, awg-quick, amneziawg-go)",
                isOn: $alsoRemoveSoftware
            )
            .toggleStyle(.checkbox)
            .font(.callout)

            HStack(spacing: 10) {
                Button("Очистить сервер-вход", role: .destructive) {
                    confirmUninstallRole = .entry
                }
                .disabled(viewModel.uninstalling != nil)

                Button("Очистить сервер-выход", role: .destructive) {
                    confirmUninstallRole = .exit
                }
                .disabled(viewModel.uninstalling != nil)

                if viewModel.uninstalling != nil {
                    ProgressView().controlSize(.small)
                }
            }
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
            Text(
                "Будут удалены юниты, правила, конфиги awg-relay и состояние /etc/amnezia/chain. Контейнер AmneziaVPN и SSH останутся рабочими."
            )
        }
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
        case .proxyNotEgressing: "Прокси не выходит через сервер-выход"
        case .accessLostAfterProxy: "После включения прокси пропал доступ"
        }
    }
}
