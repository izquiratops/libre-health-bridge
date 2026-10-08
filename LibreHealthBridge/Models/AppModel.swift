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
    var session: SavedSession?
    var connections: [Connection] = []
    var snapshot: CloudSnapshot?
    var isBusy = false
    var errorMessage: String?
    var healthAccess: HealthAccess = .notRequested
    var isPreviewCurrent = false
    var restoration: RestorationState = .idle

    @ObservationIgnored let sessionStore: any SessionStore
    @ObservationIgnored let injectedHealth: (any GlucoseWriter)?
    @ObservationIgnored lazy var health: any GlucoseWriter =
        injectedHealth ?? HealthWriter()
    @ObservationIgnored let makeClient: (Credentials) -> any CloudAPI
    @ObservationIgnored var api: (any CloudAPI)?

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
        // Load the requested synthetic UI scenario in simulator-only debug builds.
        #if DEBUG && targetEnvironment(simulator)
            if let fixtureScenario { installFixture(fixtureScenario) }
        #endif
    }

    // Keep fixture data and its in-memory cloud transport out of device and release builds.
    #if DEBUG && targetEnvironment(simulator)
        @ObservationIgnored let fixtureScenario = UIScenario
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

        enum UIScenario: String {
            case signedOut = "signed-out"
            case ready, setup, error
            case noProfiles = "no-profiles"
            case missingProfile = "missing-profile"
            case noReading = "no-reading"
            case staleReading = "stale-reading"
            case permissionDenied = "permission-denied"
            case healthUnavailable = "health-unavailable"
            case paused
            case termsRequired = "terms-required"
            case rateLimited = "rate-limited"
            case wrongPatient = "wrong-patient"
            case invalidCredentials = "invalid-credentials"
            case invalidResponse = "invalid-response"
            case secureStorage = "secure-storage"
            case healthSave = "health-save"

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
            switch scenario {
            case .permissionDenied: healthAccess = .denied
            case .healthUnavailable: healthAccess = .unavailable
            case .ready, .error, .paused, .missingProfile, .noReading,
                 .staleReading, .termsRequired, .rateLimited, .wrongPatient,
                 .invalidCredentials, .invalidResponse, .secureStorage, .healthSave:
                healthAccess = .authorized
            default: healthAccess = .notRequested
            }
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
            connections = scenario == .noProfiles || scenario == .missingProfile
                ? [] : [connection]
            let isReady = scenario != .setup && scenario != .noProfiles
                && scenario != .noReading && scenario != .staleReading
            let completedAt = TimestampParser.parse("02/18/2026 11:58:00 AM")!
            session = SavedSession(
                credentials: Credentials(
                    email: "alex@example.invalid",
                    password: ""
                ),
                selectedPatientID: scenario == .noProfiles ? nil : patientID,
                verifiedPatientID: isReady ? patientID : nil,
                lastSync: isReady ? completedAt : nil,
                syncPaused: !isReady || scenario == .paused
            )
            let errorKey: String? = switch scenario {
            case .error: "error.cloud.network"
            case .termsRequired: "error.cloud.termsRequired"
            case .rateLimited: "error.cloud.rateLimited"
            case .wrongPatient: "error.cloud.wrongPatient"
            case .invalidCredentials: "error.cloud.invalidCredentials"
            case .invalidResponse: "error.cloud.invalidResponse"
            case .secureStorage: "error.local.keychain"
            case .healthSave: "error.health.save"
            default: nil
            }
            if let errorKey {
                errorMessage = NSLocalizedString(errorKey, comment: "Fixture error")
            }
        }

        func installFixturePreview() async {
            guard !fixturePreviewLoaded, let connection = connections.first,
                fixtureScenario != .noReading else { return }
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
            isPreviewCurrent = fixtureScenario != .staleReading
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

    var isHealthSyncActive: Bool {
        isSignedIn && selectedConnection != nil && isVerified
            && healthAccess == .authorized && session?.syncPaused == false
    }

    var healthSyncStatus: String {
        if selectedConnection == nil { return "health.sync.profileMissing" }
        if !isVerified { return "checklist.sync.inactive" }
        if healthAccess != .authorized { return "health.sync.permissionOff" }
        if session?.syncPaused == true { return "health.sync.paused" }
        return "health.sync.working"
    }

    func refreshHealthAccess() {
        // Fixture scenarios use simulated Health access; do not query HealthKit.
        #if DEBUG && targetEnvironment(simulator)
            if fixtureScenario != nil { return }
        #endif
        healthAccess = health.access
    }

}
