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
    func delete() throws { saved = nil }
}

@MainActor
private final class FakeWriter: GlucoseWriter {
    var access: HealthAccess = .authorized
    var writes = 0
    func authorize() async throws {
        if access != .authorized { throw HealthError.permission }
    }
    func write(_ snapshot: CloudSnapshot, verifiedPatientID: String?) async throws -> ImportReport {
        guard access == .authorized else { throw HealthError.permission }
        guard verifiedPatientID == snapshot.patientID else { throw LocalError.validationRequired }
        writes += 1
        return ImportReport(completedAt: .now, inserted: 1, updated: 0, alreadyImported: 0, skipped: [:])
    }
}

private actor FixtureTransport: CloudTransport {
    var failConnections = false
    var failGraph = false
    var holdGraph = false
    private var pending: CheckedContinuation<Void, any Error>?
    func setConnectionsFailure(_ value: Bool) { failConnections = value }
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
            body = #"{"status":0,"data":[{"patientId":"patient-a","firstName":"Alex","glucoseMeasurement":{"FactoryTimestamp":"10/6/2026 6:30:00 AM","ValueInMgPerDl":108,"isHigh":false,"isLow":false}},{"patientId":"patient-b","firstName":"Blair"}]}"#
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
private func session(selected: String? = nil, verified: String? = nil) -> SavedSession {
    SavedSession(credentials: Credentials(email: "test@example.invalid", password: "secret"),
                 selectedPatientID: selected, verifiedPatientID: verified)
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
    #expect(app.session?.report?.inserted == 1)
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
