import SwiftUI
import VPNChainCore

/// Экран «Подключения» (задача 2.5): профили С1 и С2.
/// Вёрстка на Grid: подписи выровнены по правому краю и прижаты к полям,
/// порт SSH — в свёрнутом блоке «Дополнительно» (по умолчанию 22).
struct ConnectionsView: View {
    @StateObject private var viewModel: ConnectionsViewModel

    init(store: ProfileStore = AppServices.shared.profiles) {
        _viewModel = StateObject(wrappedValue: ConnectionsViewModel(store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProfileSectionView(role: .entry, viewModel: viewModel)
                ProfileSectionView(role: .exit, viewModel: viewModel)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Подключения")
    }
}

private struct ProfileSectionView: View {
    let role: ServerRole
    @ObservedObject var viewModel: ConnectionsViewModel
    @State private var advancedExpanded = false

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

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: sectionIcon)
                        .font(.title2)
                        .foregroundStyle(sectionTint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sectionTitle).font(.headline)
                        Text(sectionSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                mainGrid
                Divider()
                DisclosureGroup("Дополнительно", isExpanded: $advancedExpanded) {
                    advancedGrid
                        .padding(.top, 8)
                }
                .font(.body)
                buttonsRow
                statusView
            }
            .padding(12)
        }
    }

    // MARK: Основная сетка полей

    private var mainGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Хост")
                TextField("vpn.example.com", text: form.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }
            GridRow {
                Text("Пользователь")
                TextField("root", text: form.user)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }
            GridRow {
                Text("Аутентификация")
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: form.authKind) {
                        Text("Пароль").tag(ConnectionProfile.AuthKind.password)
                        Text("Ключ").tag(ConnectionProfile.AuthKind.key)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            authSpecificRows
        }
        .gridColumnAlignment(.trailing) // подписи прижаты к полям
    }

    @ViewBuilder
    private var authSpecificRows: some View {
        switch form.wrappedValue.authKind {
        case .password:
            GridRow {
                Text("Пароль")
                HStack(spacing: 8) {
                    SecureField("пароль", text: form.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    if form.wrappedValue.passwordSaved {
                        savedBadge("сохранён")
                    }
                }
            }
        case .key:
            GridRow {
                Text("Файл ключа")
                HStack(spacing: 8) {
                    TextField("~/.ssh/id_ed25519", text: form.keyPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Button("Выбрать…") {
                        if let path = Self.pickKeyFile() {
                            form.wrappedValue.keyPath = path
                        }
                    }
                }
            }
            GridRow {
                Text("")
                Toggle("Ключ с парольной фразой", isOn: form.keyHasPassphrase)
            }
            if form.wrappedValue.keyHasPassphrase {
                GridRow {
                    Text("Фраза")
                    HStack(spacing: 8) {
                        SecureField("парольная фраза", text: form.passphrase)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                        if form.wrappedValue.passphraseSaved {
                            savedBadge("сохранена")
                        }
                    }
                }
            }
        }
    }

    // MARK: Дополнительно (скрываемый блок)

    private var advancedGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Порт SSH")
                HStack(spacing: 8) {
                    TextField("22", text: form.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text("по умолчанию 22")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .gridColumnAlignment(.trailing)
    }

    // MARK: Кнопки и статус

    private var buttonsRow: some View {
        HStack(spacing: 10) {
            Button("Сохранить") {
                _ = viewModel.save(role)
            }
            Button("Проверить соединение") {
                viewModel.check(role)
            }
            .disabled(viewModel.statuses[role] == .running)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch viewModel.statuses[role] ?? .idle {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Проверяю соединение…").foregroundStyle(.secondary)
            }
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let text):
            Label(text, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func savedBadge(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Секрет уже сохранён в Keychain; введите новый, чтобы заменить")
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
