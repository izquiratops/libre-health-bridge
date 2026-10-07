import BridgeCore
import Foundation
import Security

struct SavedSession: Codable {
    var credentials: Credentials
    var selectedPatientID: String?
    var verifiedPatientID: String?
    var lastWrite: Date?
    var report: ImportReport?
}

enum LocalError: Error, LocalizedError {
    case keychain, validationRequired, noReadings, noConnections, invalidLogin
    case statusNotSaved

    var errorDescription: String? {
        switch self {
        case .keychain: "error.local.keychain"
        case .validationRequired: "error.local.validationRequired"
        case .noReadings: "error.local.noReadings"
        case .noConnections: "error.local.noConnections"
        case .invalidLogin: "error.local.invalidLogin"
        case .statusNotSaved: "error.local.statusNotSaved"
        }
    }
}

/// One device-only Keychain item holds credentials, selection, and sync status.
/// Glucose values and API tokens are not persisted here.
@MainActor
protocol SessionStore {
    func load() throws -> SavedSession?
    func save(_ session: SavedSession) throws
    func delete() throws
}

struct KeychainStore: SessionStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "LibreHealthBridge",
         kSecAttrAccount as String: "session-v1",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> SavedSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let session = try? JSONDecoder().decode(SavedSession.self, from: data)
        else { throw LocalError.keychain }
        return session
    }

    func save(_ session: SavedSession) throws {
        guard let data = try? JSONEncoder().encode(session) else { throw LocalError.keychain }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw LocalError.keychain }
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw LocalError.keychain }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalError.keychain }
    }
}
