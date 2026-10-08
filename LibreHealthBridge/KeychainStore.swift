import BridgeCore
import Foundation
import Security

struct SavedSession: Codable {
    var credentials: Credentials
    var selectedPatientID: String?
    var verifiedPatientID: String?
    var lastSync: Date?
    // Absent in sessions saved before the pause control was introduced.
    var syncPaused: Bool = false

    enum CodingKeys: String, CodingKey {
        case credentials, selectedPatientID, verifiedPatientID, lastSync, report, syncPaused
    }

    init(credentials: Credentials, selectedPatientID: String? = nil,
         verifiedPatientID: String? = nil, lastSync: Date? = nil,
         syncPaused: Bool = false) {
        self.credentials = credentials
        self.selectedPatientID = selectedPatientID
        self.verifiedPatientID = verifiedPatientID
        self.lastSync = lastSync
        self.syncPaused = syncPaused
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        credentials = try values.decode(Credentials.self, forKey: .credentials)
        selectedPatientID = try values.decodeIfPresent(String.self, forKey: .selectedPatientID)
        verifiedPatientID = try values.decodeIfPresent(String.self, forKey: .verifiedPatientID)
        // Keep the completion time from sessions saved before the Details tab was removed.
        lastSync = try values.decodeIfPresent(Date.self, forKey: .lastSync)
            ?? values.decodeIfPresent(LegacyReport.self, forKey: .report)?.completedAt
        syncPaused = try values.decodeIfPresent(Bool.self, forKey: .syncPaused) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(credentials, forKey: .credentials)
        try values.encodeIfPresent(selectedPatientID, forKey: .selectedPatientID)
        try values.encodeIfPresent(verifiedPatientID, forKey: .verifiedPatientID)
        try values.encodeIfPresent(lastSync, forKey: .lastSync)
        try values.encode(syncPaused, forKey: .syncPaused)
    }

    private struct LegacyReport: Decodable {
        let completedAt: Date
    }
}

enum LocalError: Error, LocalizedError {
    case keychain, validationRequired, noReadings, noConnections, invalidLogin
    case statusNotSaved, syncPaused

    var errorDescription: String? {
        switch self {
        case .keychain: "error.local.keychain"
        case .validationRequired: "error.local.validationRequired"
        case .noReadings: "error.local.noReadings"
        case .noConnections: "error.local.noConnections"
        case .invalidLogin: "error.local.invalidLogin"
        case .statusNotSaved: "error.local.statusNotSaved"
        case .syncPaused: "error.local.syncPaused"
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
