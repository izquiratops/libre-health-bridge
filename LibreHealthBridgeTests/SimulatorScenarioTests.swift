#if DEBUG && targetEnvironment(simulator)
import BridgeCore
import Foundation
import XCTest
@testable import LibreHealthBridge

@MainActor
final class SimulatorScenarioTests: XCTestCase {
    private func scenario(_ name: String) async -> AppModel {
        let launch = SimulatorScenarios.launch(arguments: ["--ui-scenario", name],
            production: { fatalError("A synthetic launch must never create production adapters") })
        await launch.restore()
        return launch.model
    }

    private func assertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, file: file, line: line)
    }
    private func assertOutcome(_ value: OperationOutcome, _ expected: OperationOutcome,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    func testConfirmationPermissionAndExplicitImport() async {
        let model = await scenario("setup")
        XCTAssertNotNil(model.snapshot?.preview)
        XCTAssertTrue(model.snapshot?.preview?.canValidate == true)
        XCTAssertTrue(model.isPreviewCurrent)
        XCTAssertNil(model.session?.lastSync)
        XCTAssertFalse(model.isVerified)
        XCTAssertEqual(model.healthAccess, .notRequested)
        assertTrue(await model.confirmPreview())
        XCTAssertFalse(model.isHealthSyncActive)
        assertTrue(await model.authorizeHealth())
        XCTAssertEqual(model.healthAccess, .authorized)
        XCTAssertNil(model.session?.lastSync, "Authorization must not import")
        assertOutcome(await model.sync(starting: true), .success)
        XCTAssertNotNil(model.session?.lastSync)
        XCTAssertTrue(model.isHealthSyncActive)
        assertOutcome(await model.sync(), .success)
    }

    func testPauseResumeAndLogoutLoginRetainSafeDependencies() async {
        let model = await scenario("ready")
        assertTrue(await model.stopHealthSync())
        assertOutcome(await model.sync(), .failure)
        assertOutcome(await model.sync(starting: true), .success)
        await model.logout()
        XCTAssertNil(model.session)
        await model.restore()
        XCTAssertNil(model.session)
        assertTrue(await model.login(email: "another@example.invalid", password: "synthetic"))
        XCTAssertNil(model.session?.lastSync, "Login may fetch but never imports")
        XCTAssertFalse(model.isVerified)
        assertTrue(await model.confirmPreview())
        assertOutcome(await model.sync(starting: true), .success)
    }

    func testFailureDoesNotEraseFrozenAlertOrClaimImport() async {
        let model = await scenario("health-save")
        XCTAssertNotNil(model.errorMessage)
        model.dismissError()
        let previous = model.session?.lastSync
        assertOutcome(await model.sync(), .failure)
        XCTAssertEqual(model.session?.lastSync, previous)
        XCTAssertNotNil(model.errorMessage)
    }

    func testInvalidAndIncompleteFlagsFailClosedAcrossOperations() async {
        for args in [["--ui-scenario", "unknown"], ["--ui-scenario"]] {
            let launch = SimulatorScenarios.launch(arguments: args,
                production: { fatalError("Invalid flags must fail closed") })
            let model = launch.model
            XCTAssertNil(model.session)
            XCTAssertNotNil(model.errorMessage)
            await launch.restore()
            assertTrue(await model.login(email: "fake@example.invalid", password: "synthetic"))
            assertTrue(await model.confirmPreview())
            assertTrue(await model.authorizeHealth())
            assertOutcome(await model.sync(starting: true), .success)
            await model.logout()
            XCTAssertNil(model.session)
        }
    }

    func testFreshnessAndMissingReadingUseActualCloudResponse() async {
        let missing = await scenario("no-reading")
        XCTAssertNotNil(missing.snapshot)
        XCTAssertNil(missing.snapshot?.preview)
        XCTAssertTrue(missing.isPreviewCurrent, "A successful empty response is current")
        assertTrue(!(await missing.confirmPreview()))
        XCTAssertNil(missing.session?.lastSync)

        let stale = await scenario("stale-reading")
        XCTAssertTrue(stale.snapshot?.preview?.canValidate == true)
        XCTAssertFalse(stale.isPreviewCurrent, "Launch arguments, not process arguments, control freshness")
        assertTrue(!(await stale.confirmPreview()))
        await stale.refresh()
        XCTAssertTrue(stale.isPreviewCurrent)
        assertTrue(await stale.confirmPreview())
    }

    func testSelectionRefreshAndRevocationUseInjectedAdapters() async {
        let model = await scenario("multiple-profiles")
        XCTAssertTrue(model.isVerified)
        await model.selectConnection("not-a-profile")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.selectedPatientID, "fixture-patient-01")
        await model.selectConnection("fixture-patient-02")
        XCTAssertEqual(model.selectedPatientID, "fixture-patient-02")
        XCTAssertEqual(model.snapshot?.patientID, "fixture-patient-02")
        XCTAssertNil(model.session?.lastSync)
        XCTAssertTrue(model.isPreviewCurrent)
        XCTAssertFalse(model.isVerified)
        assertOutcome(await model.sync(starting: true), .failure)
        assertTrue(await model.confirmPreview())
        await model.refresh()
        XCTAssertTrue(model.isPreviewCurrent)
        assertTrue(await model.revokePreviewConfirmation())
        XCTAssertFalse(model.isVerified)
        assertOutcome(await model.sync(starting: true), .failure)
        assertTrue(await model.confirmPreview())
        assertOutcome(await model.sync(starting: true), .success)
    }

    func testNormalLaunchNeverPreparesAfterFailedRestore() async {
        let store = RestoredScenarioTestStore()
        let connection = try! JSONDecoder().decode(Connection.self, from: Data(
            #"{"patientId":"test-patient","firstName":"Test"}"#.utf8))
        let cloud = FailingPreviewCloud(connection: connection)
        store.saved = SavedSession(credentials: Credentials(email: "test@example.invalid", password: "local"),
                                   selectedPatientID: "test-patient", syncPaused: true)
        let launch = SimulatorScenarios.launch(arguments: [], production: {
            AppModel(sessionStore: store, health: ScenarioTestWriter(), makeClient: { _ in cloud })
        })
        await launch.restore()
        XCTAssertEqual(launch.model.restoration, .retryableFailure)
        XCTAssertNil(launch.model.snapshot)
        XCTAssertNotNil(launch.model.errorMessage)
        let snapshotCalls = await cloud.snapshotCalls
        let connectionCalls = await cloud.connectionCalls
        XCTAssertEqual(snapshotCalls, 1, "Bootstrap must not retry cloud outside perform")
        XCTAssertEqual(connectionCalls, 1)
    }

    func testDeniedAndWrongPatientCannotImport() async {
        let denied = await scenario("permission-denied")
        XCTAssertEqual(denied.healthAccess, .denied)
        assertOutcome(await denied.sync(), .failure)
        XCTAssertEqual(denied.healthAccess, .denied)
        let wrong = await scenario("wrong-patient")
        XCTAssertNotNil(wrong.errorMessage)
        let previous = wrong.session?.lastSync
        assertOutcome(await wrong.sync(), .failure)
        XCTAssertEqual(wrong.session?.lastSync, previous)
    }
}

@MainActor
private final class RestoredScenarioTestStore: SessionStore {
    var saved: SavedSession?
    func load() throws -> SavedSession? { saved }
    func save(_ value: SavedSession) throws { saved = value }
    func delete() throws { saved = nil }
}

@MainActor
private final class ScenarioTestWriter: GlucoseWriter {
    var access: HealthAccess { .notRequested }
    func authorize() async throws { throw HealthError.permission }
    func write(_ snapshot: CloudSnapshot, verifiedPatientID: String?) async throws -> Date {
        throw HealthError.permission
    }
}

private actor FailingPreviewCloud: CloudAPI {
    let connection: Connection
    var connectionCalls = 0
    var snapshotCalls = 0
    init(connection: Connection) { self.connection = connection }
    func connections() async throws -> [Connection] {
        connectionCalls += 1
        return [connection]
    }
    func snapshot(for connection: Connection, now: Date?) async throws -> CloudSnapshot {
        snapshotCalls += 1
        throw CloudError.network
    }
}
#endif
