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
    var retryAfter: Date?
    var termsRequired = false
    var unauthorizedGraph = false
    var holdGraph = false
    var glucoseValue = 108
    var graphRequests = 0
    func setGlucoseValue(_ value: Int) { glucoseValue = value }
    private var pending: CheckedContinuation<Void, any Error>?
    func setConnectionsFailure(_ value: Bool) { failConnections = value }
    func setEmptyConnections(_ value: Bool) { emptyConnections = value }
    func setGraphFailure(_ value: Bool) { failGraph = value }
    func setRetryAfter(_ date: Date?) { retryAfter = date }
    func setTermsRequired(_ value: Bool) { termsRequired = value }
    func setUnauthorizedGraph(_ value: Bool) { unauthorizedGraph = value }
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
            graphRequests += 1
            if holdGraph { try await withCheckedThrowingContinuation { pending = $0 } }
            if failGraph { throw CloudError.network }
            if let retryAfter { return HTTPResult(status: 429, data: Data(), retryAfter: retryAfter) }
            if termsRequired { return HTTPResult(status: 200, data: Data(#"{"status":4}"#.utf8)) }
            if unauthorizedGraph { return HTTPResult(status: 401, data: Data()) }
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

@MainActor private final class PremiumFixture: PremiumStore {
    var state: PremiumOwnership = .notOwned
    var purchaseResult: PurchaseOutcome = .cancelled
    var failProduct = false
    var purchaseError: PremiumError?
    private var changed: (@MainActor () async -> Void)?
    func ownership() async -> PremiumOwnership { state }
    func price() async throws -> String {
        if failProduct { throw PremiumError.unavailable }
        return "$2.99" // Fixture only; the production UI uses StoreKit's localized price.
    }
    func purchase() async throws -> PurchaseOutcome {
        if failProduct { throw PremiumError.unavailable }
        if let purchaseError { throw purchaseError }
        return purchaseResult
    }
    func restore() async throws { }
    func observe(_ changed: @escaping @MainActor () async -> Void) { self.changed = changed }
    func update(_ state: PremiumOwnership) async {
        self.state = state
        await changed?()
    }
}

@MainActor private final class SchedulerFixture: RefreshScheduler {
    var pending: Date?
    var requests: [Date?] = []
    func replace(earliest: Date?) throws { pending = earliest; requests.append(earliest) }
}

@MainActor private func automaticFixture(
    _ store: MemoryStore, _ premium: PremiumFixture, _ scheduler: SchedulerFixture,
    _ clock: @escaping () -> Date, _ transport: FixtureTransport = FixtureTransport(),
    protected: @escaping () -> Bool = { true }, health: any GlucoseWriter = FakeWriter()
) -> AppModel {
    AppModel(sessionStore: store, health: health,
             makeClient: { LibreCloudClient(credentials: $0, transport: transport) },
             premium: premium, scheduler: scheduler, now: clock,
             protectedDataAvailable: protected)
}

@Test @MainActor func automaticSettingsDefaultOffAndRejectInvalidInterval() throws {
    let original = session(selected: "patient-a", verified: "patient-a")
    let decoded = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(original))
    #expect(!decoded.automaticEnabled)
    #expect(decoded.automaticInterval == 30)
    var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    payload["automaticInterval"] = 7
    let corrupted = try JSONDecoder().decode(SavedSession.self,
        from: JSONSerialization.data(withJSONObject: payload))
    #expect(corrupted.automaticInterval == 30)
    let store = MemoryStore(); store.saved = decoded
    let app = automaticFixture(store, PremiumFixture(), SchedulerFixture(), { .now })
    app.session = decoded
    app.setAutomaticInterval(7)
    #expect(store.saved?.automaticInterval == 30)
}

@Test @MainActor func purchaseAndRestoreDoNotEnableAndRevocationStops() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    let clock = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { clock }, health: health)
    await app.restore()
    await app.startPremiumObservation()
    await app.setAutomaticEnabled(true)
    #expect(store.saved?.automaticEnabled == false)
    await app.buyPremium() // cancelled
    #expect(app.ownership == .notOwned)
    premium.purchaseResult = .pending
    await app.buyPremium()
    #expect(app.ownership == .notOwned)
    #expect(app.automaticMessage == "automatic.pending")
    premium.purchaseError = .unverified
    await app.buyPremium()
    #expect(app.ownership == .notOwned)
    #expect(app.automaticMessage == "automatic.purchaseFailed")
    premium.purchaseError = nil
    premium.purchaseResult = .purchased
    await premium.update(.owned)
    await app.buyPremium()
    await app.restorePremium()
    #expect(store.saved?.automaticEnabled == false)
    #expect(health.writes == 0)
    await app.setAutomaticEnabled(true)
    #expect(scheduler.pending == clock.addingTimeInterval(1800))
    #expect(health.writes == 0)
    await premium.update(.notOwned)
    #expect(store.saved?.automaticEnabled == false)
    #expect(scheduler.pending == nil)
    #expect(health.writes == 0)
    #expect(await app.sync() == .success) // Free manual access survives revocation.
    #expect(health.writes == 1)
    #expect(scheduler.pending == nil)
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Bool] = []
    func record(_ outcome: Bool) { lock.lock(); outcomes.append(outcome); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return outcomes }
}

@Test func backgroundExpirationCompletesOnlyOnce() {
    let probe = CompletionProbe()
    let completion = RefreshCompletion { probe.record($0) }
    #expect(completion.reserveExpiration()) // Reserve while requesting the next opportunity.
    #expect(!completion.finish(true)) // A late Health completion cannot win.
    completion.finishExpiration()
    completion.finishExpiration()
    #expect(probe.values == [false])
}

@Test @MainActor func temporarilyUnknownOwnershipDefersWithoutRevokingOptIn() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    premium.state = .owned
    let time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, health: health)
    await app.restore(); await app.startPremiumObservation(); await app.setAutomaticEnabled(true)
    #expect(scheduler.pending == time.addingTimeInterval(1800))
    await premium.update(.unknown)
    #expect(store.saved?.automaticEnabled == true)
    #expect(scheduler.pending == nil)
    #expect(await app.backgroundAttempt() == .failure)
    #expect(health.writes == 0)
    #expect(await app.sync() == .success) // Unknown Premium does not block free manual sync.
    #expect(health.writes == 1)
    await premium.update(.owned)
    #expect(store.saved?.automaticEnabled == true)
    #expect(scheduler.pending == time.addingTimeInterval(3600)) // Deferred attempt's backoff.
}

@Test @MainActor func automaticCompletionSharesManualTimestampAndReschedules() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, health: health)
    await app.restore(); await app.refreshPremium()
    await app.setAutomaticEnabled(true)
    #expect(await app.backgroundAttempt() == .failure) // Not yet eligible.
    #expect(health.writes == 0)
    time = time.addingTimeInterval(3600)
    #expect(await app.backgroundAttempt() == .success)
    #expect(health.writes == 1)
    #expect(app.session?.lastSync != nil)
    #expect(scheduler.pending == time.addingTimeInterval(1800))
    time = time.addingTimeInterval(60)
    #expect(await app.sync() == .success)
    #expect(health.writes == 2)
    #expect(scheduler.pending == time.addingTimeInterval(1800))
    app.setAutomaticInterval(60)
    #expect(scheduler.pending == time.addingTimeInterval(3600))
    #expect(store.saved?.lastSync == app.session?.lastSync)
}

@Test @MainActor func protectionFailureAndConsentResetNeverImport() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    premium.state = .owned
    var unlocked = true
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, protected: { unlocked }, health: health)
    await app.restore(); await app.refreshPremium(); await app.setAutomaticEnabled(true)
    time = time.addingTimeInterval(1800)
    unlocked = false
    #expect(await app.backgroundAttempt() == .failure)
    #expect(health.writes == 0)
    #expect(store.saved?.automaticEnabled == true)
    unlocked = true
    store.failSave = true
    #expect(await app.stopHealthSync() == false)
    #expect(store.saved?.automaticEnabled == true)
    store.failSave = false
    #expect(await app.stopHealthSync())
    #expect(store.saved?.automaticEnabled == false)
    #expect(scheduler.pending == nil)
    #expect(await app.backgroundAttempt() == .failure)
    #expect(health.writes == 0)
}

@Test @MainActor func coldBackgroundLaunchFetchesOnceAndRespectsSavedCooldown() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    let transport = FixtureTransport()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let first = automaticFixture(store, premium, scheduler, { time }, transport, health: health)
    await first.restore(); await first.refreshPremium(); await first.setAutomaticEnabled(true)
    let second = automaticFixture(store, premium, scheduler, { time }, transport, health: health)
    #expect(await second.backgroundAttempt() == .failure)
    #expect(health.writes == 0)
    time = time.addingTimeInterval(1800)
    #expect(await second.backgroundAttempt() == .success)
    #expect(health.writes == 1)
    #expect(await transport.graphRequests == 2) // One foreground preview, one background import.
    #expect(store.saved?.lastSync != nil)
    #expect(await second.backgroundAttempt() == .failure)
    #expect(health.writes == 1)
}

@Test @MainActor func coldLockedKeychainLoadDefersWithoutErasingConsent() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    store.saved?.automaticEnabled = true
    store.saved?.automaticEarliest = Date(timeIntervalSince1970: 2_000_000_000)
    store.failLoad = true
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, health: health)
    #expect(await app.backgroundAttempt() == .failure)
    #expect(store.saved?.automaticEnabled == true)
    #expect(scheduler.pending == time.addingTimeInterval(3600))
    #expect(health.writes == 0)
    store.failLoad = false
    time = time.addingTimeInterval(3600)
    #expect(await app.backgroundAttempt() == .success)
    #expect(health.writes == 1)
}

@Test @MainActor func backgroundImportStorageWarningRetainsTruthfulCompletion() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, health: health)
    await app.restore(); await app.refreshPremium(); await app.setAutomaticEnabled(true)
    time = time.addingTimeInterval(1800)
    store.failSave = true
    #expect(await app.backgroundAttempt() == .completedWithStorageWarning)
    #expect(health.writes == 1)
    #expect(store.saved?.lastSync == nil)
    #expect(app.session?.lastSync != nil)
    #expect(app.errorMessage == app.safeMessage(LocalError.statusNotSaved))
    #expect(app.automaticMessage == "error.local.statusNotSaved")
    #expect(scheduler.pending == time.addingTimeInterval(3600))
}

@Test @MainActor func backgroundRateLimitPersistsLongerServerDelayAcrossIntervalChanges() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    let transport = FixtureTransport()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, transport, health: health)
    await app.restore(); await app.refreshPremium(); await app.setAutomaticEnabled(true)
    let retry = time.addingTimeInterval(7200)
    await transport.setRetryAfter(retry)
    time = time.addingTimeInterval(1800)
    #expect(await app.backgroundAttempt() == .failure)
    #expect(health.writes == 0)
    #expect(store.saved?.lastSync == nil)
    #expect(store.saved?.automaticEnabled == true)
    #expect(scheduler.pending == retry)
    app.setAutomaticInterval(15)
    #expect(scheduler.pending == retry)
    await transport.setRetryAfter(nil)
    time = retry
    #expect(await app.backgroundAttempt() == .success)
    #expect(scheduler.pending == retry.addingTimeInterval(900))
}

@Test @MainActor func termsRequireAttentionAndUnknownOwnershipDoesNotEraseConsent() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    let transport = FixtureTransport()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, transport, health: health)
    await app.restore(); await app.refreshPremium(); await app.setAutomaticEnabled(true)
    await transport.setTermsRequired(true)
    time = time.addingTimeInterval(1800)
    #expect(await app.backgroundAttempt() == .failure)
    #expect(store.saved?.automaticAttention == true)
    #expect(scheduler.pending == nil)
    #expect(health.writes == 0)
    await premium.update(.unknown)
    #expect(store.saved?.automaticEnabled == true)
    await transport.setTermsRequired(false)
    #expect(await app.backgroundAttempt() == .failure) // No silent resumption.
    #expect(health.writes == 0)
    await premium.update(.owned)
    await app.setAutomaticEnabled(false)
    await app.setAutomaticEnabled(true) // Renew explicit opt-in after resolving terms.
    #expect(store.saved?.automaticAttention == false)
}

@Test @MainActor func concurrentManualAndBackgroundNeverDuplicateImport() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    let transport = FixtureTransport()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, transport, health: health)
    await app.restore(); await app.refreshPremium(); await app.setAutomaticEnabled(true)
    time = time.addingTimeInterval(1800)
    await transport.setHoldGraph(true)
    let manual = Task { await app.sync() }
    await transport.waitForGraph()
    #expect(await app.backgroundAttempt() == .busy)
    await transport.releaseGraph()
    #expect(await manual.value == .success)
    #expect(health.writes == 1)
    #expect(scheduler.pending == time.addingTimeInterval(3600))
    #expect(store.saved?.automaticEarliest == scheduler.pending)
}

@Test @MainActor func expiredBackgroundFetchResubmitsWithoutAdvancingCompletion() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    let transport = FixtureTransport()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, transport, health: health)
    await app.restore(); await app.refreshPremium(); await app.setAutomaticEnabled(true)
    time = time.addingTimeInterval(1800)
    await transport.setHoldGraph(true)
    let work = Task { await app.backgroundAttempt() }
    await transport.waitForGraph()
    // The system expiration handler cancels work and requests a later opportunity.
    work.cancel()
    app.automaticAttemptFinished(.cancelled)
    await transport.releaseGraph()
    #expect(await work.value == .cancelled)
    #expect(health.writes == 0)
    #expect(store.saved?.lastSync == nil)
    #expect(store.saved?.automaticEnabled == true)
    #expect(scheduler.pending == time.addingTimeInterval(3600))
}

@Test @MainActor func revokedHealthPermissionRequiresExplicitSetupBeforeRenewedOptIn() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, health: health)
    await app.restore(); await app.refreshPremium(); await app.setAutomaticEnabled(true)
    time = time.addingTimeInterval(1800)
    health.access = .denied
    #expect(await app.backgroundAttempt() == .failure)
    #expect(store.saved?.automaticAttention == true)
    #expect(store.saved?.syncPaused == true)
    #expect(store.saved?.automaticEnabled == true) // Not a consent reset.
    #expect(scheduler.pending == nil)
    health.access = .authorized
    await app.setAutomaticEnabled(true)
    #expect(store.saved?.automaticAttention == true)
    #expect(health.writes == 0)
    #expect(await app.sync(starting: true) == .success)
    #expect(store.saved?.automaticAttention == true)
    await app.setAutomaticEnabled(false)
    await app.setAutomaticEnabled(true)
    #expect(store.saved?.automaticAttention == false)
    #expect(scheduler.pending == time.addingTimeInterval(1800))
}

@Test @MainActor func repeatedUnauthorizedBackgroundResponseNeedsAttention() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture(), health = FakeWriter()
    let transport = FixtureTransport()
    premium.state = .owned
    var time = Date(timeIntervalSince1970: 2_000_000_000)
    let app = automaticFixture(store, premium, scheduler, { time }, transport, health: health)
    await app.restore(); await app.refreshPremium(); await app.setAutomaticEnabled(true)
    time = time.addingTimeInterval(1800)
    await transport.setUnauthorizedGraph(true)
    #expect(await app.backgroundAttempt() == .failure)
    #expect(store.saved?.automaticAttention == true)
    #expect(scheduler.pending == nil)
    #expect(health.writes == 0)
}

@Test @MainActor func failedAutomaticPreferenceSaveNeverClaimsDurableChange() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture()
    premium.state = .owned
    let app = automaticFixture(store, premium, scheduler, { Date(timeIntervalSince1970: 2_000_000_000) })
    await app.restore(); await app.refreshPremium()
    store.failSave = true
    await app.setAutomaticEnabled(true)
    #expect(store.saved?.automaticEnabled == false)
    #expect(app.session?.automaticEnabled == false)
    #expect(scheduler.pending == nil)
    store.failSave = false
    await app.setAutomaticEnabled(true)
    #expect(store.saved?.automaticEnabled == true)
    let pending = scheduler.pending
    store.failSave = true
    await app.setAutomaticEnabled(false)
    #expect(store.saved?.automaticEnabled == true)
    #expect(app.session?.automaticEnabled == true)
    #expect(scheduler.pending == pending)
    #expect(app.automaticMessage == "error.local.statusNotSaved")
}

@Test @MainActor func unavailableProductDoesNotChangeOwnershipOrConsent() async {
    let store = MemoryStore(); store.saved = session(selected: "patient-a", verified: "patient-a")
    let premium = PremiumFixture(), scheduler = SchedulerFixture()
    premium.failProduct = true
    let app = automaticFixture(store, premium, scheduler, { .now })
    await app.restore(); await app.startPremiumObservation()
    #expect(app.premiumPrice == nil)
    #expect(app.ownership == .notOwned)
    await app.buyPremium()
    #expect(app.automaticMessage == "automatic.purchaseFailed")
    await app.setAutomaticEnabled(true)
    #expect(store.saved?.automaticEnabled == false)
}
