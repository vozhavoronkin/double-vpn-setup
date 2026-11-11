import Foundation
import VPNChainCore

/// Общие сервисы приложения (единый ProfileStore для всех экранов).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let profiles: ProfileStore

    private init() {
        self.profiles = ProfileStore()
    }
}
