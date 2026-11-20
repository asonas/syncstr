import Foundation
import Security

actor LegacyKeychainCleanup {
    private static let shared = LegacyKeychainCleanup()

    nonisolated static func schedule() {
        Task(priority: .utility) { await shared.run() }
    }

    func run(defaults: UserDefaults = .standard, delete: (String) -> OSStatus = { service in
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecAttrAccount: "last-login"] as CFDictionary)
    }) {
        let key = "legacyPairingCredentialsRemoved"
        guard !defaults.bool(forKey: key) else { return }
        var completed = true
        for service in ["as.ason.syncstr.local-pair", "as.ason.syncstr.p2p.identity", "as.ason.syncstr.p2p.peer"] {
            let status = delete(service)
            if status != errSecSuccess && status != errSecItemNotFound { completed = false }
        }
        if completed { defaults.set(true, forKey: key) }
    }
}
