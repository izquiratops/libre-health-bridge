import BridgeCore
import Foundation
import HealthKit
import Testing
@testable import LibreHealthBridge

@MainActor
private final class MemoryStore: SessionStore {
    var saved: SavedSession?
    var failLoad = false
    var failSave = false
    var failDelete = false
    var saveCount = 0
    func load() throws -> SavedSession? {
        if failLoad { throw LocalError.keychain }
        return saved
    }
    func save(_ session: SavedSession) throws {
        saveCount += 1
        if failSave { throw LocalError.keychain }
        saved = session
    }
    func delete() throws {
        if failDelete { throw LocalError.keychain }
        saved = nil
    }
}

@MainActor
private final class FakeWriter: GlucoseWriter {
    var access: HealthAccess = .authorized
    var writes = 0
    func authorize() async throws {
        if access != .authorized { throw HealthError.permission }
    }
    func write(_ snapshot: CloudSnapshot, verifiedPatientID: String?) async throws -> Date {
        guard access == .authorized else { throw HealthError.permission }
        guard verifiedPatientID == snapshot.patientID else { throw LocalError.validationRequired }
        writes += 1
        return .now
    }
}

private actor FixtureTransport: CloudTransport {
    var failConnections = false
    var emptyConnections = false
    var failGraph = false
    var holdGraph = false
    private var pending: CheckedContinuation<Void, any Error>?
    func setConnectionsFailure(_ value: Bool) { failConnections = value }
    func setEmptyConnections(_ value: Bool) { emptyConnections = value }
    func setGraphFailure(_ value: Bool) { failGraph = value }
    func setHoldGraph(_ value: Bool) { holdGraph = value }
    func waitForGraph() async {
        while pending == nil { await Task.yield() }
    }
    func releaseGraph() async {
        await waitForGraph()
        pending?.resume()
        pending = nil
    }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let body: String
        switch request.url?.path {
        case "/llu/auth/login":
            body = #"{"status":0,"data":{"user":{"id":"user"},"authTicket":{"token":"token"}}}"#
        case "/llu/connections":
            if failConnections { throw CloudError.network }
            body = emptyConnections ? #"{"status":0,"data":[]}"# :
                #"{"status":0,"data":[{"patientId":"patient-a","firstName":"Alex","glucoseMeasurement":{"FactoryTimestamp":"10/6/2026 6:30:00 AM","ValueInMgPerDl":108,"isHigh":false,"isLow":false}},{"patientId":"patient-b","firstName":"Blair"}]}"#
        case "/llu/connections/patient-a/graph", "/llu/connections/patient-b/graph":
            if holdGraph { try await withCheckedThrowingContinuation { pending = $0 } }
            if failGraph { throw CloudError.network }
            let id = request.url!.pathComponents[3]
            body = "{\"status\":0,\"data\":{\"connection\":{\"patientId\":\"\(id)\"},\"graphData\":[]}}"
        default: throw CloudError.invalidResponse
        }
        return HTTPResult(status: 200, data: Data(body.utf8))
    }
}

@MainActor
private func model(_ store: MemoryStore, _ health: FakeWriter, _ transport: FixtureTransport) -> AppModel {
    AppModel(sessionStore: store, health: health,
             makeClient: { LibreCloudClient(credentials: $0, transport: transport) })
}

@MainActor
private func session(selected: String? = nil, verified: String? = nil, paused: Bool = false) -> SavedSession {
    SavedSession(credentials: Credentials(email: "test@example.invalid", password: "secret"),
                 selectedPatientID: selected, verifiedPatientID: verified, syncPaused: paused)
}

@MainActor
private final class FakeHealthStore: GlucoseHealthStore {
    var access: HealthAccess = .authorized
    var saves = 0
    var cancelDuringQuery = false
    func authorize() async throws { }
    func existingSamples(for readings: [GlucoseReading]) async throws -> [StoredReading] {
        if cancelDuringQuery { withUnsafeCurrentTask { $0?.cancel() } }
        return []
    }
    func save(_ samples: [HKQuantitySample]) async throws { saves += 1 }
}

@Test @MainActor func writerChecksCancellationBeforeSaving() async throws {
    let transport = FixtureTransport()
    let api = LibreCloudClient(credentials: Credentials(email: "test@example.invalid", password: "secret"),
                               transport: transport)
    let connection = try #require(try await api.connections().first)
    let snapshot = try await api.snapshot(for: connection,
        now: TimestampParser.parse("10/6/2026 7:00:00 AM")!)
    let backend = FakeHealthStore()
    backend.cancelDuringQuery = true
    let writer = HealthWriter(backend: backend)
    let operation = Task { try await writer.write(snapshot, verifiedPatientID: connection.patientId) }
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(backend.saves == 0)
}

@Test @MainActor func restoreFailureCanRetryWithoutRestart() async {
    let store = MemoryStore()
    store.saved = session()
    let transport = FixtureTransport()
    await transport.setConnectionsFailure(true)
    let app = model(store, FakeWriter(), transport)
    await app.restore()
    #expect(app.restoration == .retryableFailure)
    #expect(app.connections.isEmpty)
    await transport.setConnectionsFailure(false)
    await app.refresh() // The setup screen offers this even without a selected profile.
    #expect(app.restoration == .loaded)
    #expect(app.connections.count == 2)
}

@Test @MainActor func profileSwitchClearsVerification() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let app = model(store, FakeWriter(), FixtureTransport())
    await app.restore()
    #expect(app.isVerified)
    await app.selectConnection("patient-b")
    #expect(!app.isVerified)
    #expect(store.saved?.verifiedPatientID == nil)
    #expect(app.selectedPatientID == "patient-b")
}

@Test @MainActor func firstSyncRequiresProfileConfirmationAndPermission() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", paused: true)
    let health = FakeWriter()
    let app = model(store, health, FixtureTransport())
    await app.restore()
    #expect(!app.isHealthSyncActive)
    #expect(await app.sync() == .failure)
    #expect(health.writes == 0)
    #expect(await app.confirmPreview())
    #expect(!app.isHealthSyncActive) // Closing setup cannot start sync.
    health.access = .denied
    app.refreshHealthAccess()
    #expect(await app.sync(starting: true) == .failure)
    #expect(!app.isHealthSyncActive)
    health.access = .authorized
    app.refreshHealthAccess()
    #expect(!app.isHealthSyncActive)
    #expect(await app.sync(starting: true) == .success)
    #expect(app.isHealthSyncActive)
    #expect(health.writes == 1)
}

@Test @MainActor func confirmationSwitchCanRevokeAndRequiresConfirmationAgain() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", paused: true)
    let health = FakeWriter()
    let app = model(store, health, FixtureTransport())
    await app.restore()
    #expect(await app.confirmPreview())
    #expect(app.isVerified)
    #expect(await app.revokePreviewConfirmation())
    #expect(!app.isVerified)
    #expect(store.saved?.verifiedPatientID == nil)
    #expect(store.saved?.syncPaused == true)
    #expect(await app.sync(starting: true) == .failure)
    #expect(health.writes == 0)
    #expect(await app.confirmPreview())
    #expect(app.isVerified)
}

@Test @MainActor func failedRevocationKeepsConfirmation() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let app = model(store, FakeWriter(), FixtureTransport())
    await app.restore()
    store.failSave = true
    #expect(await app.revokePreviewConfirmation() == false)
    #expect(app.isVerified)
    #expect(store.saved?.verifiedPatientID == "patient-a")
}

@Test @MainActor func stoppingSyncPersistsAndRequiresSetupToResume() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let health = FakeWriter()
    let app = model(store, health, FixtureTransport())
    await app.restore()
    #expect(app.isHealthSyncActive)
    #expect(await app.stopHealthSync())
    #expect(!app.isHealthSyncActive)
    #expect(app.healthSyncStatus == "health.sync.paused")
    #expect(store.saved?.syncPaused == true)
    #expect(await app.sync() == .failure)
    #expect(health.writes == 0)

    let restored = model(store, health, FixtureTransport())
    await restored.restore()
    #expect(!restored.isHealthSyncActive)
    #expect(await restored.sync(starting: true) == .success)
    #expect(restored.isHealthSyncActive)
    #expect(store.saved?.syncPaused == false)
    #expect(health.writes == 1)
}

@Test @MainActor func permissionAndMissingProfileShowSetupStatus() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let health = FakeWriter()
    let app = model(store, health, FixtureTransport())
    await app.restore()
    health.access = .denied
    app.refreshHealthAccess()
    #expect(!app.isHealthSyncActive)
    #expect(app.healthSyncStatus == "health.sync.permissionOff")
    app.connections = []
    #expect(!app.isHealthSyncActive)
    #expect(app.healthSyncStatus == "health.sync.profileMissing")
}

@Test @MainActor func legacySessionDefaultsToNotPaused() throws {
    let original = session(selected: "patient-a", verified: "patient-a")
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json.removeValue(forKey: "syncPaused")
    let restored = try JSONDecoder().decode(SavedSession.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(!restored.syncPaused)
}

@Test @MainActor func legacySessionRetainsLastSyncWithoutSavingImportCounts() throws {
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session())) as? [String: Any])
    let completedAt = Date(timeIntervalSince1970: 1_760_000_000)
    json["report"] = ["completedAt": completedAt.timeIntervalSinceReferenceDate,
                      "inserted": 3, "updated": 1, "alreadyImported": 2, "skipped": [:]] as [String: Any]
    json["lastWrite"] = completedAt.timeIntervalSinceReferenceDate
    let restored = try JSONDecoder().decode(SavedSession.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.lastSync == completedAt)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
    #expect(encoded["report"] == nil)
    #expect(encoded["lastWrite"] == nil)
    #expect(encoded["lastSync"] != nil)
}

@Test @MainActor func permissionDenialPreventsWrites() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let health = FakeWriter()
    health.access = .denied
    let app = model(store, health, FixtureTransport())
    await app.restore()
    #expect(await app.sync() == .failure)
    #expect(health.writes == 0)
}

@Test @MainActor func healthSuccessAndStorageFailureReportsWarning() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let health = FakeWriter()
    let app = model(store, health, FixtureTransport())
    await app.restore()
    store.failSave = true
    #expect(await app.sync() == .completedWithStorageWarning)
    #expect(health.writes == 1)
    #expect(app.session?.lastSync != nil)
    #expect(app.errorMessage != nil)
}

@Test @MainActor func failedRefreshDoesNotImportOldPreview() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let health = FakeWriter()
    let transport = FixtureTransport()
    let app = model(store, health, transport)
    await app.restore()
    #expect(app.snapshot != nil)
    await transport.setGraphFailure(true)
    #expect(await app.sync() == .failure)
    #expect(health.writes == 0)
    #expect(app.snapshot != nil)
    #expect(!app.isPreviewCurrent)
}

@Test @MainActor func cancelledSyncCannotWriteOrLeaveFailureFeedback() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let health = FakeWriter()
    let transport = FixtureTransport()
    let app = model(store, health, transport)
    await app.restore()
    await transport.setHoldGraph(true)
    let running = Task { await app.sync() }
    await transport.waitForGraph()
    running.cancel()
    await transport.releaseGraph()
    #expect(await running.value == .cancelled)
    #expect(health.writes == 0)
}

@Test @MainActor func emptyCredentialsAndNoConnectionsCannotCreateSession() async {
    let store = MemoryStore()
    let transport = FixtureTransport()
    let app = model(store, FakeWriter(), transport)
    #expect(await app.login(email: " ", password: "") == false)
    #expect(app.errorMessage == app.safeMessage(LocalError.invalidLogin))
    await transport.setEmptyConnections(true)
    #expect(await app.login(email: "test@example.invalid", password: "secret") == false)
    #expect(app.errorMessage == app.safeMessage(LocalError.noConnections))
    #expect(store.saved == nil)
    #expect(app.session == nil)
}

@Test @MainActor func failedLogoutKeepsSessionAndReportsSecureStorageError() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let app = model(store, FakeWriter(), FixtureTransport())
    await app.restore()
    store.failDelete = true
    await app.logout()
    #expect(app.isSignedIn)
    #expect(app.selectedPatientID == "patient-a")
    #expect(app.errorMessage == app.safeMessage(LocalError.keychain))
    store.failDelete = false
    await app.logout()
    #expect(!app.isSignedIn)
    #expect(store.saved == nil)
    #expect(app.connections.isEmpty)
}

@Test @MainActor func staleOrAbsentPreviewCannotBeConfirmed() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a")
    let app = model(store, FakeWriter(), FixtureTransport())
    await app.restore()
    app.isPreviewCurrent = false
    #expect(await app.confirmPreview() == false)
    #expect(store.saved?.verifiedPatientID == nil)
    app.isPreviewCurrent = true
    app.snapshot = nil
    #expect(await app.confirmPreview() == false)
    #expect(store.saved?.verifiedPatientID == nil)
}

@Test @MainActor func missingProfileAndUnavailableHealthCannotWrite() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let health = FakeWriter()
    let app = model(store, health, FixtureTransport())
    await app.restore()
    app.connections = []
    #expect(await app.sync() == .failure)
    #expect(health.writes == 0)
    await app.refresh()
    health.access = .unavailable
    app.refreshHealthAccess()
    #expect(await app.sync() == .failure)
    #expect(health.writes == 0)
}

@Test @MainActor func failedStorageDuringFirstImportKeepsSyncPaused() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a", paused: true)
    let health = FakeWriter()
    let app = model(store, health, FixtureTransport())
    await app.restore()
    store.failSave = true
    #expect(await app.sync(starting: true) == .completedWithStorageWarning)
    #expect(health.writes == 1)
    #expect(!app.isHealthSyncActive)
    #expect(app.session?.syncPaused == true)
    #expect(store.saved?.syncPaused == true)
}

@Test @MainActor func busySyncCannotReplaceActiveFeedback() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let transport = FixtureTransport()
    let app = model(store, FakeWriter(), transport)
    await app.restore()
    await transport.setHoldGraph(true)
    let first = Task { await app.sync() }
    // Wait until the first operation has entered the actor-suspended request.
    while !app.isBusy { await Task.yield() }
    #expect(await app.sync() == .busy)
    await transport.releaseGraph()
    #expect(await first.value == .success)
}
