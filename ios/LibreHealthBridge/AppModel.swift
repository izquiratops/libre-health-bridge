import BridgeCore
import Foundation
import Observation

enum OperationOutcome: Equatable {
    case success, completedWithStorageWarning, cancelled, busy, failure
}

enum RestorationState {
    case idle, loading, loaded, retryableFailure
}

protocol CloudAPI: Sendable {
    func connections() async throws -> [Connection]
    func snapshot(for connection: Connection, now: Date?) async throws
        -> CloudSnapshot
}

extension LibreCloudClient: CloudAPI {}

@MainActor
@Observable
final class AppModel {
    private(set) var session: SavedSession?
    private(set) var connections: [Connection] = []
    private(set) var snapshot: CloudSnapshot?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var healthAccess: HealthAccess = .notRequested
    private(set) var isPreviewCurrent = false
    private(set) var restoration: RestorationState = .idle

    @ObservationIgnored private let sessionStore: any SessionStore
    @ObservationIgnored private let injectedHealth: (any GlucoseWriter)?
    @ObservationIgnored private lazy var health: any GlucoseWriter =
        injectedHealth ?? HealthWriter()
    @ObservationIgnored private let makeClient: (Credentials) -> any CloudAPI
    @ObservationIgnored private var api: (any CloudAPI)?

    init(
        sessionStore: any SessionStore = KeychainStore(),
        health: (any GlucoseWriter)? = nil,
        makeClient: @escaping (Credentials) -> any CloudAPI = {
            LibreCloudClient(credentials: $0)
        }
    ) {
        self.sessionStore = sessionStore
        self.injectedHealth = health
        self.makeClient = makeClient
        #if DEBUG && targetEnvironment(simulator)
            if let fixtureScenario { installFixture(fixtureScenario) }
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
        @ObservationIgnored private let fixtureScenario = UIScenario
            .launchArgument
        @ObservationIgnored private var fixturePreviewLoaded = false

        private struct FixtureTransport: CloudTransport {
            let graphResponse: Data

            func send(_ request: URLRequest) async throws -> HTTPResult {
                let data: Data
                switch request.url?.path {
                case "/llu/auth/login":
                    data = Data(
                        #"{"status":0,"data":{"user":{"id":"fixture-user"},"authTicket":{"token":"fixture-token"}}}"#
                            .utf8
                    )
                case "/llu/connections/fixture-patient-01/graph":
                    data = graphResponse
                default:
                    throw CloudError.invalidResponse
                }
                return HTTPResult(status: 200, data: data)
            }
        }

        private enum UIScenario: String {
            case signedOut = "signed-out"
            case ready, setup, error

            static var launchArgument: Self? {
                let args = ProcessInfo.processInfo.arguments
                guard let index = args.firstIndex(of: "--ui-scenario"),
                    args.indices.contains(index + 1)
                else { return nil }
                return Self(rawValue: args[index + 1])
            }
        }

        private func installFixture(_ scenario: UIScenario) {
            restoration = .loaded
            healthAccess =
                scenario == .ready || scenario == .error
                ? .authorized : .notRequested
            guard scenario != .signedOut else { return }

            // All values are synthetic and fixed. No cloud client, keychain item, or HealthKit store is used.
            let patientID = "fixture-patient-01"
            // Connection has a decoding-only public API; decode the same shape as a cloud response.
            let connection = try! JSONDecoder().decode(
                Connection.self,
                from: Data(
                    #"{"patientId":"fixture-patient-01","firstName":"Alex","lastName":"Rivera","glucoseMeasurement":{"FactoryTimestamp":"02/18/2026 11:55:00 AM","Timestamp":"02/18/2026 11:55:00 AM","ValueInMgPerDl":112,"isHigh":false,"isLow":false}}"#
                        .utf8
                )
            )
            connections = [connection]
            let isReady = scenario != .setup
            let completedAt = TimestampParser.parse("02/18/2026 11:58:00 AM")!
            session = SavedSession(
                credentials: Credentials(
                    email: "alex@example.invalid",
                    password: ""
                ),
                selectedPatientID: patientID,
                verifiedPatientID: isReady ? patientID : nil,
                lastWrite: isReady ? completedAt : nil,
                report: isReady
                    ? ImportReport(
                        completedAt: completedAt,
                        inserted: 6,
                        updated: 1,
                        alreadyImported: 1,
                        skipped: [.flaggedHigh: 1]
                    ) : nil
            )
            if scenario == .error {
                errorMessage = NSLocalizedString(
                    "error.cloud.network",
                    comment: "Fixture cloud error"
                )
            }
        }

        private func installFixturePreview() async {
            guard !fixturePreviewLoaded, let connection = connections.first
            else { return }
            fixturePreviewLoaded = true
            let timestamps = [
                "11:20", "11:25", "11:30", "11:35", "11:40", "11:45", "11:50",
                "11:55",
            ]
            let values = [105, 108, 110, 107, 109, 111, 114, 112]
            let history: [[String: Any]] =
                zip(timestamps, values).map { time, value in
                    [
                        "FactoryTimestamp": "02/18/2026 \(time):00 AM",
                        "ValueInMgPerDl": value,
                        "isHigh": false, "isLow": false,
                    ]
                } + [
                    [
                        "FactoryTimestamp": "02/18/2026 11:15:00 AM",
                        "ValueInMgPerDl": 350,
                        "isHigh": true, "isLow": false,
                    ]
                ]
            let graph = try! JSONSerialization.data(withJSONObject: [
                "status": 0,
                "data": [
                    "connection": ["patientId": connection.patientId],
                    "graphData": history,
                ],
            ])
            // The in-memory transport cannot make a network request. The resulting snapshot uses
            // BridgeCore's real validation and normalization, with a fixed clock.
            let client = LibreCloudClient(
                credentials: Credentials(
                    email: "fixture@example.invalid",
                    password: ""
                ),
                transport: FixtureTransport(graphResponse: graph)
            )
            snapshot = try! await client.snapshot(
                for: connection,
                now: TimestampParser.parse("02/18/2026 12:00:00 PM")!
            )
        }
    #endif

    var isSignedIn: Bool { session != nil }
    var selectedPatientID: String? { session?.selectedPatientID }
    var selectedConnection: Connection? {
        connections.first { $0.patientId == selectedPatientID }
    }
    var isVerified: Bool {
        guard let selectedPatientID else { return false }
        return session?.verifiedPatientID == selectedPatientID
    }

    func refreshHealthAccess() {
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil { return }
        #endif
        healthAccess = health.access
    }

    func restore() async {
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil {
                await installFixturePreview()
                return
            }
        #endif
        guard restoration == .idle || restoration == .retryableFailure else {
            return
        }
        restoration = .loading
        refreshHealthAccess()
        let result = await perform {
            guard let saved = try sessionStore.load() else { return }
            session = saved
            api = makeClient(saved.credentials)
            try await fetchPreview()
        }
        restoration = result == .success ? .loaded : .retryableFailure
    }

    func login(email: String, password: String) async -> Bool {
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil { return false }
        #endif
        return await perform {
            let credentials = Credentials(email: email, password: password)
            guard !credentials.email.isEmpty, !password.isEmpty else {
                throw LocalError.invalidLogin
            }
            let client = makeClient(credentials)
            let available = try await client.connections()
            guard !available.isEmpty else { throw LocalError.noConnections }
            let saved = SavedSession(
                credentials: credentials,
                selectedPatientID: available.count == 1
                    ? available[0].patientId : nil
            )
            try sessionStore.save(saved)
            session = saved
            restoration = .loaded
            api = client
            connections = available
            // A graph error must not keep the password in the login form after successful login.
            if saved.selectedPatientID != nil {
                do { try await fetchPreview(refreshConnections: false) } catch {
                    errorMessage = safeMessage(error)
                }
            }
        } == .success
    }

    // Switching profiles clears verification and local status, never existing Health samples.
    func selectConnection(_ id: String) async {
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil { return }
        #endif
        _ = await perform {
            guard var saved = session, saved.selectedPatientID != id else {
                return
            }
            guard connections.contains(where: { $0.patientId == id }) else {
                throw CloudError.missingConnection
            }
            saved.selectedPatientID = id
            saved.verifiedPatientID = nil
            saved.lastWrite = nil
            saved.report = nil
            isPreviewCurrent = false
            try sessionStore.save(saved)
            session = saved
            snapshot = nil
            try await fetchPreview(refreshConnections: false)
        }
    }

    func refresh() async {
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil { return }
        #endif
        guard isSignedIn else {
            if restoration == .retryableFailure { await restore() }
            return
        }
        let result = await perform { try await fetchPreview() }
        if result == .success { restoration = .loaded }
        if result == .failure { restoration = .retryableFailure }
    }

    @discardableResult
    func confirmPreview() async -> Bool {
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil { return false }
        #endif
        return await perform {
            guard var saved = session, let id = saved.selectedPatientID,
                isPreviewCurrent, snapshot?.patientID == id,
                snapshot?.preview?.canValidate == true
            else { throw LocalError.noReadings }
            saved.verifiedPatientID = id
            try sessionStore.save(saved)
            session = saved
        } == .success
    }

    @discardableResult
    func authorizeHealth() async -> Bool {
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil { return false }
        #endif
        return await perform {
            guard isVerified else { throw LocalError.validationRequired }
            defer { refreshHealthAccess() }
            try await health.authorize()
        } == .success
    }

    @discardableResult
    func sync() async -> OperationOutcome {
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil { return .cancelled }
        #endif
        let result = await perform {
            guard isVerified else { throw LocalError.validationRequired }
            refreshHealthAccess()
            guard healthAccess == .authorized else {
                throw HealthError.permission
            }
            // Always refetch the selected connection. Never import an old preview after an error.
            try await fetchPreview(persistStatus: false)
            guard let snapshot, var saved = session,
                saved.selectedPatientID == snapshot.patientID
            else { throw CloudError.missingConnection }
            let report = try await health.write(
                snapshot,
                verifiedPatientID: saved.verifiedPatientID
            )
            saved.report = report
            if report.wroteSamples { saved.lastWrite = report.completedAt }
            session = saved
            do { try sessionStore.save(saved) } catch {
                errorMessage = safeMessage(LocalError.statusNotSaved)
            }
        }
        return result == .success && errorMessage != nil
            ? .completedWithStorageWarning : result
    }

    func logout() async {
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil { return }
        #endif
        _ = await perform {
            // Clear the UI only after deletion succeeds, so failure cannot hide retained credentials.
            try sessionStore.delete()
            api = nil
            session = nil
            restoration = .idle
            connections = []
            snapshot = nil
            isPreviewCurrent = false
        }
    }

    func dismissError() { errorMessage = nil }

    private func fetchPreview(
        refreshConnections: Bool = true,
        persistStatus: Bool = true
    ) async throws {
        guard let api, let saved = session else { return }
        do {
            if refreshConnections { connections = try await api.connections() }
            guard let id = saved.selectedPatientID else { return }
            guard
                let connection = connections.first(where: { $0.patientId == id }
                )
            else {
                throw CloudError.missingConnection
            }
            let result = try await api.snapshot(for: connection, now: nil)
            try Task.checkCancellation()
            snapshot = result
            isPreviewCurrent = true
        } catch {
            isPreviewCurrent = false
            throw error
        }
        session = saved
        if persistStatus {
            do { try sessionStore.save(saved) } catch {
                throw LocalError.statusNotSaved
            }
        }
    }

    private func perform(_ operation: () async throws -> Void) async
        -> OperationOutcome
    {
        guard !isBusy else { return .busy }
        isBusy = true
        errorMessage = nil
        defer {
            isBusy = false
            refreshHealthAccess()
        }
        do {
            try await operation()
            return .success
        } catch is CancellationError { return .cancelled } catch {
            errorMessage = safeMessage(error)
            return .failure
        }
    }

    private func safeMessage(_ error: any Error) -> String {
        // Only our deliberately redacted messages can reach the UI.
        if let error = error as? CloudError {
            switch error {
            case .http(let code):
                return String(
                    format: NSLocalizedString(
                        "error.cloud.http",
                        comment: "HTTP failure"
                    ),
                    code
                )
            case .api(let code):
                return String(
                    format: NSLocalizedString(
                        "error.cloud.api",
                        comment: "API failure"
                    ),
                    code
                )
            default:
                return NSLocalizedString(
                    error.localizedDescription,
                    comment: "Cloud error"
                )
            }
        }
        if let error = error as? LocalError {
            return NSLocalizedString(
                error.localizedDescription,
                comment: "Local error"
            )
        }
        if let error = error as? HealthError {
            return NSLocalizedString(
                error.localizedDescription,
                comment: "Health error"
            )
        }
        if let error = error as? ImportPlanningError {
            return NSLocalizedString(
                error.localizedDescription,
                comment: "Import error"
            )
        }
        return NSLocalizedString("error.unknown", comment: "Unknown error")
    }
}
