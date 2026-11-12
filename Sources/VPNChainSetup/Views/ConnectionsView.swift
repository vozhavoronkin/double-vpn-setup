import AppKit
import SwiftUI
import VPNChainCore

/// Экран «Подключения» (задача 2.5): два профиля — «Сервер-вход» и «Сервер-выход».
/// Карточки идут адаптивной сеткой: две колонки на широком окне, одна на узком.
/// Порт SSH — в свёрнутом блоке «Дополнительно» (по умолчанию 22).
struct ConnectionsView: View {
    @StateObject private var viewModel: ConnectionsViewModel

    init(store: ProfileStore = AppServices.shared.profiles) {
        _viewModel = StateObject(wrappedValue: ConnectionsViewModel(store: store))
    }

    var body: some View {
        PageScaffold {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 360), spacing: AppTheme.sectionSpacing)],
                alignment: .leading,
                spacing: AppTheme.sectionSpacing
            ) {
                ProfileSectionView(role: .entry, viewModel: viewModel)
                ProfileSectionView(role: .exit, viewModel: viewModel)
            }
        }
        .navigationTitle("Подключения")
    }
}

private struct ProfileSectionView: View {
    let role: ServerRole
    @ObservedObject var viewModel: ConnectionsViewModel
    @State private var advancedExpanded = false
    @State private var saveError: String?

    private var sectionTitle: String {
        role == .entry ? "Сервер-вход" : "Сервер-выход"
    }

    private var sectionSubtitle: String {
        role == .entry
            ? "Принимает клиентов AmneziaVPN и пересылает трафик на сервер-выход"
            : "Выпускает трафик в интернет — его IP увидят клиенты"
    }

    private var sectionIcon: String {
        role == .entry ? "arrow.right.to.line" : "globe"
    }

    private var sectionTint: Color {
        role == .entry ? .blue : .green
    }

    private var form: Binding<ConnectionsViewModel.ProfileForm> {
        Binding(
            get: { viewModel.form(role) },
            set: { viewModel.setForm(role, $0) }
        )
    }

    private var isChecking: Bool {
        viewModel.status(for: role) == .running
    }

    /// Пилюля профиля: проверка важнее факта сохранения.
    private var pill: (kind: StatusKind, text: String) {
        switch viewModel.status(for: role) {
        case .running:
            (.progress, "Проверяю")
        case .success:
            (.ok, "Проверен")
        case .failure:
            (.error, "Ошибка")
        case .idle:
            (.neutral, viewModel.isConfigured(role) ? "Настроен" : "Не настроен")
        }
    }

    var body: some View {
        Card(
            title: sectionTitle,
            systemImage: sectionIcon,
            subtitle: sectionSubtitle,
            tint: sectionTint,
            accessory: { StatusPill(kind: pill.kind, text: pill.text) }
        ) {
            mainFields
            Divider()
            DisclosureGroup("Дополнительно", isExpanded: $advancedExpanded) {
                portField.padding(.top, 6)
            }
            .font(.callout)
            feedback
            actions
        }
    }

    // MARK: Поля

    private var mainFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledField("Хост") {
                TextField("", text: form.host)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runCheck)
                    .accessibilityLabel("Хост сервера")
            }
            LabeledField("Пользователь") {
                TextField("", text: form.user)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runCheck)
                    .accessibilityLabel("Пользователь SSH")
            }
            LabeledField("Аутентификация") {
                Picker("Аутентификация", selection: form.authKind) {
                    Text("Пароль").tag(ConnectionProfile.AuthKind.password)
                    Text("Ключ").tag(ConnectionProfile.AuthKind.key)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Способ аутентификации")
            }
            authSpecificFields
        }
    }

    @ViewBuilder
    private var authSpecificFields: some View {
        switch form.wrappedValue.authKind {
        case .password:
            LabeledField("Пароль") {
                HStack(spacing: 8) {
                    SecureField("", text: form.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(runCheck)
                        .accessibilityLabel("Пароль SSH")
                    if form.wrappedValue.passwordSaved {
                        savedBadge("сохранён")
                    }
                }
            }
        case .key:
            LabeledField("Файл ключа") {
                HStack(spacing: 8) {
                    TextField("", text: form.keyPath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Путь к файлу ключа")
                    Button("Выбрать…") {
                        if let path = Self.pickKeyFile() {
                            form.wrappedValue.keyPath = path
                        }
                    }
                }
            }
            Toggle("Ключ с парольной фразой", isOn: form.keyHasPassphrase)
                .toggleStyle(.checkbox)
            if form.wrappedValue.keyHasPassphrase {
                LabeledField("Парольная фраза") {
                    HStack(spacing: 8) {
                        SecureField("", text: form.passphrase)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(runCheck)
                            .accessibilityLabel("Парольная фраза ключа")
                        if form.wrappedValue.passphraseSaved {
                            savedBadge("сохранена")
                        }
                    }
                }
            }
        }
    }

    private var portField: some View {
        LabeledField("Порт SSH") {
            HStack(spacing: 8) {
                TextField("", text: form.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .accessibilityLabel("Порт SSH")
                Text("по умолчанию 22")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Обратная связь

    @ViewBuilder
    private var feedback: some View {
        if let saveError {
            Banner(kind: .error, text: saveError)
        }
        switch viewModel.status(for: role) {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Проверяю соединение…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .success(let text):
            Banner(kind: .success, text: text)
        case .failure(let text):
            Banner(kind: .error, text: text)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Сохранить", action: save)
            Button("Проверить соединение", action: runCheck)
                .buttonStyle(.borderedProminent)
                .disabled(isChecking)
        }
    }

    private func save() {
        saveError = viewModel.save(role)
        if saveError == nil {
            AppServices.shared.commands.noteProfilesChanged()
        }
    }

    private func runCheck() {
        saveError = nil
        viewModel.check(role)
        AppServices.shared.commands.noteProfilesChanged()
    }

    private func savedBadge(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.seal.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Секрет уже сохранён в Keychain; введите новый, чтобы заменить")
            .accessibilityLabel("Секрет \(text) в Keychain")
    }

    /// Диалог выбора файла ключа (AppKit).
    static func pickKeyFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Выберите приватный ключ OpenSSH (ed25519/ecdsa)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
