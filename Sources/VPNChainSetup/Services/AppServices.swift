import Foundation
import VPNChainCore

/// Команда меню «Цепочка». Выполняется активным экраном.
enum AppCommand: Equatable {
    case refreshStatus
    case startInstall
    case runDiagnostics
}

/// Мост между меню-командами и экранами: одна общая «очередь» вместо focus-binding на каждый экран.
/// Экран потребляет команду и сбрасывает её, поэтому повторный вызов команды снова срабатывает.
@MainActor
final class AppCommandRouter: ObservableObject {
    @Published private(set) var pending: AppCommand?
    /// Счётчик вызовов: экраны подписаны на него, а не на `pending`, чтобы повторная команда не терялась.
    @Published private(set) var pendingToken = 0
    /// Меняется при сохранении профилей: от этого зависит доступность пункта меню «Начать установку».
    @Published private(set) var profilesRevision = 0

    func send(_ command: AppCommand) {
        pending = command
        pendingToken += 1
    }

    func consume(_ command: AppCommand) {
        if pending == command {
            pending = nil
        }
    }

    func noteProfilesChanged() {
        profilesRevision += 1
    }
}

/// Общие сервисы приложения (единый ProfileStore для всех экранов).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let profiles: ProfileStore
    let commands = AppCommandRouter()

    private init() {
        self.profiles = ProfileStore()
    }
}
