import Foundation
import Security

struct PairingCredentials: Codable, Equatable, Sendable {
    let libraryID: String
    let name: String
    let key: String

    // Keep existing paired-device records readable across app updates.
    enum CodingKeys: String, CodingKey {
        case libraryID = "server", name = "username", key = "password"
    }
}

actor CredentialStore {
    private let service: String
    private let label: String

    init(service: String, label: String = "syncstr paired device") {
        self.service = service
        self.label = label
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "last-login"
        ]
    }

    func load() throws -> PairingCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(PairingCredentials.self, from: data)
    }

    func save(_ credentials: PairingCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            item[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: Error {
    let status: OSStatus
}
