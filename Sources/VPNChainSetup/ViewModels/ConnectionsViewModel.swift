import AppKit
import Foundation
import VPNChainCore

/// ViewModel экрана «Подключения»: формы С1/С2, сохранение, проверка соединения.
@MainActor
final class ConnectionsViewModel: ObservableObject {
    enum CheckStatus: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    /// Форма редактирования одного профиля. Пароль/фраза — транзиентные
    /// (пустое значение = «не менять сохранённое»).
    struct ProfileForm {
        var host: String = ""
        var port: String = "22"
        var user: String = "root"
        var authKind: ConnectionProfile.AuthKind = .password
        var keyPath: String = ""
        var keyHasPassphrase: Bool = false
        var password: String = ""
        var passphrase: String = ""
        var passwordSaved = false
        var passphraseSaved = false

        init() {}

        init(from profile: ConnectionProfile, store: ProfileStore) {
            self.host = profile.host
            self.port = String(profile.port)
            self.user = profile.user
            self.authKind = profile.authKind
            self.keyPath = profile.keyPath ?? ""
            self.keyHasPassphrase = profile.keyHasPassphrase
            self.passwordSaved = store.hasSecret(profileID: profile.id, kind: .password)
            self.passphraseSaved = store.hasSecret(profileID: profile.id, kind: .passphrase)
        }

        func toProfile(role: ServerRole, existing: ConnectionProfile?) -> ConnectionProfile {
            var profile =
                existing
                ?? ConnectionProfile(role: role, host: host, user: user, authKind: authKind)
            profile.role = role
            profile.host = host.trimmingCharacters(in: .whitespaces)
            profile.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? 22
            profile.user = user.trimmingCharacters(in: .whitespaces)
            profile.authKind = authKind
            profile.keyPath = authKind == .key && !keyPath.isEmpty ? keyPath : nil
            profile.keyHasPassphrase = authKind == .key ? keyHasPassphrase : false
            return profile
        }
    }

    @Published private(set) var forms: [ServerRole: ProfileForm] = [
        .entry: ProfileForm(), .exit: ProfileForm(),
    ]
    @Published private(set) var statuses: [ServerRole: CheckStatus] = [.entry: .idle, .exit: .idle]

    private let store: ProfileStore

    init(store: ProfileStore) {
        self.store = store
        reload()
    }

    func reload() {
        for role in ServerRole.allCases {
            if let profile = store.profile(for: role) {
                forms[role] = ProfileForm(from: profile, store: store)
            }
        }
    }

    func form(_ role: ServerRole) -> ProfileForm {
        forms[role] ?? ProfileForm()
    }

    func updateForm(_ role: ServerRole, mutate: (inout ProfileForm) -> Void) {
        var form = self.form(role)
        mutate(&form)
        forms[role] = form
    }

    /// Полная замена формы (для Binding во view).
    func setForm(_ role: ServerRole, _ form: ProfileForm) {
        forms[role] = form
    }

    /// Профиль сохранён (независимо от результата проверки соединения).
    func isConfigured(_ role: ServerRole) -> Bool {
        store.profile(for: role) != nil
    }

    /// Текущее состояние проверки соединения (для статус-пилюли карточки).
    func status(for role: ServerRole) -> CheckStatus {
        statuses[role] ?? .idle
    }

    /// Сохраняет профиль и секреты. Возвращает текст ошибки либо nil.
    @discardableResult
    func save(_ role: ServerRole) -> String? {
        guard let form = forms[role] else { return nil }
        let profile = form.toProfile(role: role, existing: store.profile(for: role))
        if let validation = store.upsert(profile) {
            return UserMessages.text(of: validation)
        }
        do {
            switch form.authKind {
            case .password:
                if !form.password.isEmpty {
                    try store.setPassword(form.password, profileID: profile.id)
                }
            case .key:
                if form.keyHasPassphrase, !form.passphrase.isEmpty {
                    try store.setPassphrase(form.passphrase, profileID: profile.id)
                }
            }
        } catch {
            return "Не удалось сохранить секрет в Keychain: \(error)"
        }
        reload()
        return nil
    }

    func clearSecrets(_ role: ServerRole) {
        guard let profile = store.profile(for: role) else { return }
        store.deleteSecrets(profileID: profile.id)
        reload()
    }

    /// Проверка соединения: сохраняет форму и запускает контрольное подключение.
    func check(_ role: ServerRole) {
        if let error = save(role) {
            statuses[role] = .failure(error)
            return
        }
        guard let profile = store.profile(for: role) else { return }
        statuses[role] = .running
        let store = self.store
        let host = profile.host
        Task { [weak self] in
            let checker = ConnectionChecker(store: store) { fingerprint in
                await Self.confirmFingerprint(host: host, fingerprint: fingerprint)
            }
            do {
                let environment = try await checker.check(profile)
                self?.statuses[role] = .success(environment.displayText)
            } catch {
                self?.statuses[role] = .failure(UserMessages.text(of: error))
            }
        }
    }

    /// Диалог TOFU-подтверждения отпечатка host key (общий для всех экранов).
    nonisolated static func confirmFingerprint(host: String, fingerprint: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Неизвестный сервер"
            alert.informativeText = """
                Сервер \(host) представился отпечатком:

                \(fingerprint)

                Принять и сохранить его в профиле?
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Принять")
            alert.addButton(withTitle: "Отклонить")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}

/// Тексты ошибок для UI.
enum UserMessages {
    static func text(of error: Error) -> String {
        switch error {
        case let validation as ConnectionProfile.ValidationError:
            text(of: validation)
        case let check as ConnectionChecker.CheckError:
            text(of: check)
        case let ssh as SSHError:
            text(of: ssh)
        case let provisioning as ProvisioningError:
            text(of: provisioning)
        default:
            "Ошибка: \(error.localizedDescription)"
        }
    }

    static func text(of provisioning: ProvisioningError) -> String {
        switch provisioning {
        case .dockerMissing(let detail):
            "Docker недоступен на сервере: \(detail)"
        case .containerMissing:
            "Контейнер AmneziaWG не найден — сначала установите AmneziaWG из приложения AmneziaVPN"
        case .unsupportedPlatform(let detail):
            "Неподдерживаемая платформа: \(detail)"
        case .parseFailed(let detail):
            "Не удалось разобрать вывод команды: \(detail)"
        case .commandFailed(let step, let exitCode, let stderr):
            "Шаг «\(step)» завершился с ошибкой (код выхода \(exitCode.map(String.init) ?? "неизвестен")). \(shortened(stderr))"
        }
    }

    /// Хвост stderr/journal'а: причина почти всегда в последних строках.
    private static func shortened(_ text: String, limit: Int = 800) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + trimmed.suffix(limit)
    }

    static func text(of validation: ConnectionProfile.ValidationError) -> String {
        switch validation {
        case .hostEmpty: "Укажите хост сервера"
        case .portOutOfRange: "Порт должен быть от 1 до 65535"
        case .userEmpty: "Укажите пользователя"
        case .keyPathMissing: "Выберите файл приватного ключа"
        case .passwordNotSet: "Задайте пароль"
        }
    }

    static func text(of check: ConnectionChecker.CheckError) -> String {
        switch check {
        case .profileInvalid(let detail): "Профиль некорректен: \(detail)"
        case .secretMissing(let detail): "Секрет не задан: \(detail)"
        case .hostKeyChanged:
            """
            Отпечаток host key изменился — соединение отклонено. \
            Если вы переустановили сервер, откройте профиль и подтвердите новый отпечаток.
            """
        }
    }

    static func text(of ssh: SSHError) -> String {
        switch ssh {
        case .connectionFailed(let detail): "Не удалось подключиться: \(detail)"
        case .authFailed(let detail): "Отказ в аутентификации: \(detail)"
        case .hostKeyRejected: "Host key отклонён"
        case .timeout(let detail): "Таймаут: \(detail)"
        case .closedUnexpectedly(let detail): "Соединение закрыто: \(detail)"
        case .unsupportedKey(let detail): detail
        case .keyParsing(let detail): "Не удалось разобрать ключ: \(detail)"
        case .wrongPassphrase: "Неверная парольная фраза ключа"
        case .cancelled: "Операция отменена"
        }
    }
}
