import Foundation
import Security
import Testing
@testable import VPNChainCore

/// Тесты задачи 2.2: профили в UserDefaults, секреты — в Keychain.
/// Секрет не должен появиться в JSON профилей ни в каком виде.
struct ProfileStoreTests {
    private func makeStore() -> ProfileStore {
        let suiteName = "vpnchain-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ProfileStore(defaults: defaults, keychain: KeychainStore(service: "ru.vpnchain.tests"))
    }

    @Test func passwordGoesToKeychainAndNotToUserDefaults() throws {
        let suiteName = "vpnchain-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ProfileStore(defaults: defaults, keychain: KeychainStore(service: "ru.vpnchain.tests"))

        let profile = ConnectionProfile(
            role: .entry,
            host: "10.0.0.1",
            user: "root",
            authKind: .password
        )
        store.upsert(profile)
        let secret = "s3cr3t-пароль-42"
        try store.setPassword(secret, profileID: profile.id)

        // 1. Секрет читается из Keychain.
        #expect(store.password(profileID: profile.id) == secret)
        #expect(store.isReady(profile))

        // 2. Секрета нет ни в одном значении UserDefaults (в т.ч. в JSON профилей).
        let allValues = defaults.dictionaryRepresentation()
        for (key, value) in allValues {
            let description = "\(key)=\(value)"
            #expect(!description.contains(secret), "Секрет утёк в UserDefaults: \(key)")
        }
    }

    @Test func profileRoundtrip() throws {
        let store = makeStore()
        let profile = ConnectionProfile(
            role: .exit,
            host: "vpn2.example.com",
            port: 2222,
            user: "admin",
            authKind: .key,
            keyPath: "/Users/dev/.ssh/id_ed25519",
            keyHasPassphrase: true,
            hostKeyFingerprint: "SHA256:abc123"
        )
        store.upsert(profile)
        let loaded = store.profile(id: profile.id)
        #expect(loaded == profile)
        #expect(store.profile(for: .exit)?.id == profile.id)
        #expect(store.passphrase(profileID: profile.id) == nil) // фраза ещё не задана
    }

    @Test func deleteRemovesProfileAndSecrets() throws {
        let store = makeStore()
        let profile = ConnectionProfile(role: .entry, host: "h", user: "root", authKind: .password)
        store.upsert(profile)
        try store.setPassword("p", profileID: profile.id)

        store.delete(id: profile.id)
        #expect(store.profile(id: profile.id) == nil)
        #expect(store.password(profileID: profile.id) == nil)
        #expect(!store.isReady(profile))
    }

    @Test func validationRules() {
        let emptyHost = ConnectionProfile(role: .entry, host: " ", user: "root", authKind: .password)
        #expect(emptyHost.validate() == .hostEmpty)

        let badPort = ConnectionProfile(role: .entry, host: "h", port: 0, user: "root", authKind: .password)
        #expect(badPort.validate() == .portOutOfRange)

        let emptyUser = ConnectionProfile(role: .entry, host: "h", user: "", authKind: .password)
        #expect(emptyUser.validate() == .userEmpty)

        let missingKey = ConnectionProfile(role: .entry, host: "h", user: "root", authKind: .key)
        #expect(missingKey.validate() == .keyPathMissing)

        let good = ConnectionProfile(role: .entry, host: "h", user: "root", authKind: .password)
        #expect(good.validate() == nil)
    }

    @Test func readinessRequiresSecret() throws {
        let store = makeStore()
        let passwordProfile = ConnectionProfile(role: .entry, host: "h", user: "root", authKind: .password)
        store.upsert(passwordProfile)
        #expect(!store.isReady(passwordProfile)) // пароля ещё нет
        try store.setPassword("x", profileID: passwordProfile.id)
        #expect(store.isReady(passwordProfile))
    }
}
