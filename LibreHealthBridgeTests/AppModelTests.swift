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
    var glucoseValue = 108
    func setGlucoseValue(_ value: Int) { glucoseValue = value }
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
                """
                {"status":0,"data":[{"patientId":"patient-a","firstName":"Alex",\
                "glucoseMeasurement":{"FactoryTimestamp":"02/18/2026 11:55:00 AM",\
                "ValueInMgPerDl":\(glucoseValue),"isHigh":false,"isLow":false}},\
                {"patientId":"patient-b","firstName":"Blair"}]}
                """
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
private func model(_ store: MemoryStore, _ health: any GlucoseWriter, _ transport: FixtureTransport) -> AppModel {
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

// Mimics only the store behavior the writer relies on: queries return committed samples,
// and a higher sync version replaces the previous sample for that identifier.
// This is not a simulation of HealthKit authorization, queries, or save semantics.
@MainActor
private final class RecordingHealthStore: GlucoseHealthStore {
    let access: HealthAccess = .authorized
    private(set) var samples: [String: HKQuantitySample] = [:]
    private(set) var saveAttempts = 0
    var failSave = false
    func authorize() async throws { }
    func existingSamples(for readings: [GlucoseReading]) async throws -> [StoredReading] {
        let ids = Set(readings.map(\.id))
        let unit = HKUnit(from: "mg/dL")
        return samples.compactMap { id, sample in
            guard ids.contains(id),
                  let version = sample.metadata?[HKMetadataKeySyncVersion] as? Int else { return nil }
            return StoredReading(id: id, valueMgDl: sample.quantity.doubleValue(for: unit), version: version)
        }
    }
    func save(_ writes: [HKQuantitySample]) async throws {
        saveAttempts += 1
        if failSave { throw HealthError.save }
        var next = samples
        for sample in writes {
            guard let id = sample.metadata?[HKMetadataKeySyncIdentifier] as? String,
                  let version = sample.metadata?[HKMetadataKeySyncVersion] as? Int else {
                throw HealthError.save
            }
            let previousVersion = next[id]?.metadata?[HKMetadataKeySyncVersion] as? Int ?? 0
            if version > previousVersion { next[id] = sample }
        }
        samples = next
    }
}

@Test @MainActor func firstImportSavesGlucoseSampleWithIdentityAndMetadata() async throws {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let backend = RecordingHealthStore()
    let app = model(store, HealthWriter(backend: backend), FixtureTransport())
    await app.restore()

    #expect(await app.sync() == .success)
    let sample = try #require(backend.samples.values.first)
    #expect(backend.samples.count == 1)
    #expect(sample.quantity.doubleValue(for: HKUnit(from: "mg/dL")) == 108)
    let measurementTime = Date(timeIntervalSince1970: 1_771_415_700) // 2026-02-18 11:55:00 UTC
    #expect(sample.startDate == measurementTime)
    #expect(sample.endDate == measurementTime)
    let identity = "libre-health-bridge.v1.7b29ea7cc5eb6c66bc76a17446b7dd28ee894491aed81b16fad2224d89893362"
    #expect(sample.metadata?[HKMetadataKeySyncIdentifier] as? String == identity)
    #expect(sample.metadata?[HKMetadataKeySyncVersion] as? Int == 1)
    #expect(sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == false)
    #expect(sample.metadata?["org.librehealthbridge.source"] as? String == "LibreLinkUp cloud import")
    #expect(sample.metadata?["org.librehealthbridge.measurementKind"] as? String == "Interstitial glucose")
    #expect(backend.saveAttempts == 1)
    #expect(store.saved?.lastSync != nil)
}

@Test @MainActor func repeatedImportKeepsOneStoredReadingWithoutSavingAgain() async throws {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let backend = RecordingHealthStore()
    let app = model(store, HealthWriter(backend: backend), FixtureTransport())
    await app.restore()
    #expect(await app.sync() == .success)
    let first = try #require(backend.samples.values.first)

    #expect(await app.sync() == .success)
    #expect(backend.samples.count == 1)
    #expect(backend.saveAttempts == 1)
    #expect(backend.samples.values.first?.uuid == first.uuid)
    #expect(backend.samples.values.first?.metadata?[HKMetadataKeySyncVersion] as? Int == 1)
}

@Test @MainActor func correctedCloudReadingReplacesStoredSampleAtNextVersion() async throws {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let backend = RecordingHealthStore()
    let transport = FixtureTransport()
    let app = model(store, HealthWriter(backend: backend), transport)
    await app.restore()
    #expect(await app.sync() == .success)
    let original = try #require(backend.samples.values.first)
    let identity = try #require(original.metadata?[HKMetadataKeySyncIdentifier] as? String)

    await transport.setGlucoseValue(117)
    #expect(await app.sync() == .success)
    let corrected = try #require(backend.samples[identity])
    #expect(backend.samples.count == 1)
    #expect(backend.saveAttempts == 2)
    #expect(corrected.uuid != original.uuid)
    #expect(corrected.quantity.doubleValue(for: HKUnit(from: "mg/dL")) == 117)
    #expect(corrected.startDate == Date(timeIntervalSince1970: 1_771_415_700))
    #expect(corrected.endDate == corrected.startDate)
    #expect(corrected.metadata?[HKMetadataKeySyncIdentifier] as? String == identity)
    #expect(corrected.metadata?[HKMetadataKeySyncVersion] as? Int == 2)
    #expect(corrected.metadata?[HKMetadataKeyWasUserEntered] as? Bool == false)
    #expect(corrected.metadata?["org.librehealthbridge.source"] as? String == "LibreLinkUp cloud import")
    #expect(corrected.metadata?["org.librehealthbridge.measurementKind"] as? String == "Interstitial glucose")
}

@Test @MainActor func failedCorrectionSavePreservesHealthSampleAndLastCompletedSync() async throws {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let backend = RecordingHealthStore()
    let transport = FixtureTransport()
    let app = model(store, HealthWriter(backend: backend), transport)
    await app.restore()
    #expect(await app.sync() == .success)
    let original = try #require(backend.samples.values.first)
    let identity = try #require(original.metadata?[HKMetadataKeySyncIdentifier] as? String)
    let completedAt = try #require(store.saved?.lastSync)

    await transport.setGlucoseValue(117)
    backend.failSave = true
    #expect(await app.sync() == .failure)
    #expect(app.errorMessage == app.safeMessage(HealthError.save))
    #expect(backend.saveAttempts == 2)
    #expect(backend.samples.count == 1)
    #expect(backend.samples[identity]?.uuid == original.uuid)
    #expect(backend.samples[identity]?.quantity.doubleValue(for: HKUnit(from: "mg/dL")) == 108)
    #expect(store.saved?.lastSync == completedAt)
    #expect(app.session?.lastSync == completedAt)

    backend.failSave = false
    #expect(await app.sync() == .success)
    #expect(backend.samples.count == 1)
    #expect(backend.samples[identity]?.quantity.doubleValue(for: HKUnit(from: "mg/dL")) == 117)
    #expect(backend.samples[identity]?.metadata?[HKMetadataKeySyncVersion] as? Int == 2)
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

@Test @MainActor func completedHealthSaveWithFailedSessionSaveWarnsAndKeepsStartingSyncPaused() async throws {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a", paused: true)
    let backend = RecordingHealthStore()
    let app = model(store, HealthWriter(backend: backend), FixtureTransport())
    await app.restore()
    store.failSave = true

    #expect(await app.sync(starting: true) == .completedWithStorageWarning)
    let sample = try #require(backend.samples.values.first)
    #expect(backend.samples.count == 1)
    #expect(backend.saveAttempts == 1)
    #expect(sample.quantity.doubleValue(for: HKUnit(from: "mg/dL")) == 108)
    #expect(sample.startDate == Date(timeIntervalSince1970: 1_771_415_700))
    #expect(sample.endDate == sample.startDate)
    #expect(sample.metadata?[HKMetadataKeySyncVersion] as? Int == 1)
    #expect(!app.isHealthSyncActive)
    #expect(app.session?.syncPaused == true)
    #expect(store.saved?.syncPaused == true)
    #expect(app.session?.lastSync != nil) // The Health write finished.
    #expect(store.saved?.lastSync == nil) // Persistence did not finish.
    #expect(app.errorMessage == app.safeMessage(LocalError.statusNotSaved))
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

@Test @MainActor func setupConfirmationRequiresCurrentMatchingValidPreview() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", paused: true)
    let transport = FixtureTransport()
    let app = model(store, FakeWriter(), transport)
    await app.restore()
    #expect(app.canConfirmPreview)
    let previousPreview = app.snapshot

    await transport.setGraphFailure(true)
    await app.refresh() // A failed fetch leaves the displayed preview stale.
    #expect(!app.canConfirmPreview)
    #expect(await app.confirmPreview() == false)
    await transport.setGraphFailure(false)
    await app.selectConnection("patient-b") // No measurement in this profile.
    #expect(!app.canConfirmPreview)
    #expect(await app.confirmPreview() == false)
    app.snapshot = previousPreview // Simulate a late preview for the old patient.
    app.isPreviewCurrent = true
    #expect(!app.canConfirmPreview)
    #expect(await app.confirmPreview() == false)
    #expect(store.saved?.verifiedPatientID == nil)
}

@Test @MainActor func setupImportCanRefetchStalePreviewButNeedsProfileAndPermission() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a", paused: true)
    let health = FakeWriter()
    let transport = FixtureTransport()
    let app = model(store, health, transport)
    await app.restore()
    await transport.setGraphFailure(true)
    await app.refresh()
    #expect(!app.canConfirmPreview)
    #expect(app.canStartHealthSync) // Import refetches; confirmation cannot use this preview.
    #expect(await app.sync(starting: true) == .failure)
    #expect(health.writes == 0)
    await transport.setGraphFailure(false)
    #expect(await app.sync() == .failure) // Ordinary import cannot resume a pause.
    #expect(await app.sync(starting: true) == .success)
    #expect(health.writes == 1)
    #expect(app.isHealthSyncActive)

    health.access = .denied
    #expect(await app.sync() == .failure) // Permission is refreshed at execution.
    #expect(health.writes == 1)
    #expect(!app.canStartHealthSync)
    health.access = .authorized
    app.refreshHealthAccess()
    #expect(health.writes == 1) // Permission recovery alone does not import.
    await transport.setEmptyConnections(true)
    await app.refresh()
    #expect(app.selectedConnection == nil)
    #expect(!app.canStartHealthSync)
    #expect(await app.sync(starting: true) == .failure)
    #expect(health.writes == 1)
}

@Test @MainActor func primaryActionPersistsPauseBeforeOpeningSetupOnPermissionOrProfileLoss() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let health = FakeWriter()
    let transport = FixtureTransport()
    let app = model(store, health, transport)
    await app.restore()
    health.access = .denied
    #expect(await app.primaryHealthAction() == .openSetup)
    #expect(store.saved?.syncPaused == true)
    #expect(!app.isHealthSyncActive)
    health.access = .authorized
    app.refreshHealthAccess()
    #expect(await app.primaryHealthAction() == .openSetup)
    #expect(health.writes == 0) // Recovery requires an explicit setup resume.

    let missingStore = MemoryStore()
    missingStore.saved = session(selected: "patient-a", verified: "patient-a")
    let missingTransport = FixtureTransport()
    let missing = model(missingStore, FakeWriter(), missingTransport)
    await missing.restore()
    await missingTransport.setEmptyConnections(true)
    await missing.refresh()
    #expect(missing.selectedConnection == nil)
    #expect(await missing.primaryHealthAction() == .openSetup)
    #expect(missingStore.saved?.syncPaused == true)
}

@Test @MainActor func failedPausePreventsSetupAndPreservesSession() async {
    let store = MemoryStore()
    store.saved = session(selected: "patient-a", verified: "patient-a")
    let health = FakeWriter()
    let app = model(store, health, FixtureTransport())
    await app.restore()
    health.access = .denied
    store.failSave = true
    #expect(await app.primaryHealthAction() == .stay)
    #expect(store.saved?.syncPaused == false)
    #expect(app.session?.syncPaused == false)
    #expect(app.errorMessage == app.safeMessage(LocalError.keychain))
    #expect(health.writes == 0)
    store.failSave = false
    #expect(await app.primaryHealthAction() == .openSetup)
    #expect(store.saved?.syncPaused == true)
}
