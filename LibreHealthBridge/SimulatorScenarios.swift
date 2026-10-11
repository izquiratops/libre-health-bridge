#if DEBUG && targetEnvironment(simulator)
import BridgeCore
import Foundation
import HealthKit
import SwiftUI
import UIKit

// The only launch seam for synthetic journeys. Even an unrecognized flag selects safe
// adapters; it must never fall through to AppModel's production defaults.
@MainActor
enum SimulatorScenarios {
    enum Scenario: String {
        case signedOut = "signed-out"
        case ready, setup, error
        case noProfiles = "no-profiles", missingProfile = "missing-profile"
        case multipleProfiles = "multiple-profiles"
        case noReading = "no-reading", staleReading = "stale-reading"
        case permissionDenied = "permission-denied", healthUnavailable = "health-unavailable"
        case paused, termsRequired = "terms-required", rateLimited = "rate-limited"
        case wrongPatient = "wrong-patient", invalidCredentials = "invalid-credentials"
        case invalidResponse = "invalid-response", secureStorage = "secure-storage"
        case healthSave = "health-save"
        case premiumReady = "premium-ready", premiumSetup = "premium-setup"
        case premiumRefreshOff = "premium-refresh-off", premiumAttention = "premium-attention"
    }

    private static let patientID = "fixture-patient-01"
    private static let credentials = Credentials(email: "alex@example.invalid", password: "fixture-password")
    private static let completedAt = TimestampParser.parse("02/18/2026 11:58:00 AM")!

    @MainActor
    struct Composition {
        let model: AppModel
        private let scenario: Scenario?

        fileprivate init(model: AppModel, scenario: Scenario?) {
            self.model = model
            self.scenario = scenario
        }

        func restore() async {
            await model.restore()
            // Normal launches, including failed restores, never run scenario preparation.
            guard let scenario, model.session != nil, model.snapshot == nil,
                  let api = model.api, let connection = model.selectedConnection else { return }
            // Use the same decoded cloud data as refresh and sync. A successful empty response
            // is current but cannot be confirmed; stale-reading deliberately requires refresh.
            model.snapshot = try? await api.snapshot(for: connection, now: nil)
            model.isPreviewCurrent = model.snapshot != nil && scenario != .staleReading
        }
    }

    static func launch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        production: () -> AppModel = { AppModel() }
    ) -> Composition {
        guard let index = arguments.firstIndex(of: "--ui-scenario") else {
            return Composition(model: production(), scenario: nil)
        }
        let scenario = arguments.indices.contains(index + 1) ? Scenario(rawValue: arguments[index + 1]) : nil
        let store = ScenarioStore()
        let access: HealthAccess
        switch scenario {
        case .permissionDenied: access = .denied
        case .healthUnavailable: access = .unavailable
        case .ready, .paused, .error, .missingProfile, .multipleProfiles, .noReading, .staleReading,
             .premiumReady, .premiumRefreshOff, .premiumAttention,
             .termsRequired, .rateLimited, .wrongPatient, .invalidCredentials,
             .invalidResponse, .secureStorage, .healthSave: access = .authorized
        case .signedOut, .setup, .premiumSetup, .noProfiles, nil: access = .notRequested
        }
        let backend = ScenarioHealthStore(access: access, failsSave: scenario == .healthSave)
        let model = AppModel(sessionStore: store, health: HealthWriter(backend: backend), makeClient: { credentials in
            ScenarioClient(credentials: credentials, scenario: scenario)
        }, premium: ScenarioPremiumStore(owned: [.premiumReady, .premiumSetup, .premiumRefreshOff,
                                                  .premiumAttention].contains(scenario)),
           scheduler: ScenarioRefreshScheduler(),
           backgroundRefreshAvailable: { scenario != .premiumRefreshOff &&
               UIApplication.shared.backgroundRefreshStatus == .available })
        model.restoration = .loaded
        model.refreshHealthAccess()
        guard let scenario else {
            model.errorMessage = model.safeMessage(CloudError.invalidResponse)
            return Composition(model: model, scenario: nil)
        }
        guard scenario != .signedOut else { return Composition(model: model, scenario: scenario) }
        let ready = scenario != .setup && scenario != .premiumSetup && scenario != .noProfiles &&
            scenario != .noReading && scenario != .staleReading
        var saved = SavedSession(credentials: credentials,
            selectedPatientID: scenario == .noProfiles ? nil : patientID,
            verifiedPatientID: ready ? patientID : nil,
            lastSync: ready ? completedAt : nil,
            syncPaused: !ready || scenario == .paused)
        if scenario == .premiumRefreshOff || scenario == .premiumAttention {
            saved.automaticEnabled = true
            saved.automaticAttention = scenario == .premiumAttention
        }
        store.seed(saved)
        model.session = saved
        model.connections = scenario == .noProfiles || scenario == .missingProfile ? [] :
            [ScenarioClient.connection(noReading: scenario == .noReading)] +
            (scenario == .multipleProfiles ? [ScenarioClient.secondConnection] : [])
        model.api = model.makeClient(credentials)
        // Frozen error cards remain visible until dismissed; bootstrap never calls perform().
        let error: (any Error)? = switch scenario {
        case .error: CloudError.network
        case .termsRequired: CloudError.termsRequired
        case .rateLimited: CloudError.rateLimited
        case .wrongPatient: CloudError.wrongPatient
        case .invalidCredentials: CloudError.invalidCredentials
        case .invalidResponse: CloudError.invalidResponse
        case .secureStorage: LocalError.keychain
        case .healthSave: HealthError.save
        default: nil
        }
        if let error { model.errorMessage = model.safeMessage(error) }
        if scenario == .secureStorage { store.failsSave = true }
        return Composition(model: model, scenario: scenario)
    }
}

@MainActor private struct ScenarioRefreshScheduler: RefreshScheduler {
    func replace(earliest: Date?) throws { }
}

@MainActor private final class ScenarioPremiumStore: PremiumStore {
    let owned: Bool
    init(owned: Bool) { self.owned = owned }
    func ownership() async -> PremiumOwnership { owned ? .owned : .notOwned }
    func price() async throws -> String { "$2.99" } // Synthetic UI price only.
    func purchase() async throws -> PurchaseOutcome { .cancelled }
    func restore() async throws { }
    func observe(_ changed: @escaping @MainActor () async -> Void) { }
}

@MainActor
private final class ScenarioStore: SessionStore {
    private var saved: SavedSession?
    var failsSave = false
    func seed(_ value: SavedSession) { saved = value }
    func load() throws -> SavedSession? { saved }
    func save(_ value: SavedSession) throws {
        if failsSave { throw LocalError.keychain }
        saved = value
    }
    func delete() throws { saved = nil }
}

@MainActor
private final class ScenarioHealthStore: GlucoseHealthStore {
    var access: HealthAccess
    let failsSave: Bool
    private var samples: [HKQuantitySample] = []
    init(access: HealthAccess, failsSave: Bool) {
        self.access = access
        self.failsSave = failsSave
    }
    func authorize() async throws {
        if access == .unavailable { throw HealthError.unavailable }
        if access == .denied { throw HealthError.permission }
        access = .authorized
    }
    func existingSamples(for readings: [GlucoseReading]) async throws -> [StoredReading] {
        samples.compactMap { sample in
            guard let id = sample.metadata?[HKMetadataKeySyncIdentifier] as? String else { return nil }
            return StoredReading(id: id, valueMgDl: sample.quantity.doubleValue(for: HKUnit(from: "mg/dL")),
                version: sample.metadata?[HKMetadataKeySyncVersion] as? Int ?? 0)
        }
    }
    func save(_ values: [HKQuantitySample]) async throws {
        if failsSave { throw HealthError.save }
        samples.append(contentsOf: values)
    }
}

private struct ScenarioClient: CloudAPI {
    let credentials: Credentials
    let scenario: SimulatorScenarios.Scenario?

    static func connection(noReading: Bool = false) -> Connection {
        let measurement = noReading ? "" :
            #", "glucoseMeasurement":{"FactoryTimestamp":"02/18/2026 11:55:00 AM","Timestamp":"02/18/2026 11:55:00 AM","ValueInMgPerDl":112,"isHigh":false,"isLow":false}"#
        return try! JSONDecoder().decode(Connection.self, from: Data(
            (#"{"patientId":"fixture-patient-01","firstName":"Alex","lastName":"Rivera""# + measurement + "}").utf8))
    }

    static var secondConnection: Connection {
        try! JSONDecoder().decode(Connection.self, from: Data(
            #"{"patientId":"fixture-patient-02","firstName":"Blair","lastName":"Rivera","glucoseMeasurement":{"FactoryTimestamp":"02/18/2026 11:50:00 AM","ValueInMgPerDl":105,"isHigh":false,"isLow":false}}"#.utf8))
    }

    private var client: LibreCloudClient {
        LibreCloudClient(credentials: credentials, transport: ScenarioTransport(scenario: scenario))
    }
    func connections() async throws -> [Connection] { try await client.connections() }
    func snapshot(for connection: Connection, now: Date?) async throws -> CloudSnapshot {
        try await client.snapshot(for: connection, now: TimestampParser.parse("02/18/2026 12:00:00 PM")!)
    }
}

private struct ScenarioTransport: CloudTransport {
    let scenario: SimulatorScenarios.Scenario?
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let body: String
        switch request.url?.path {
        case "/llu/auth/login":
            body = #"{"status":0,"data":{"user":{"id":"fixture-user"},"authTicket":{"token":"fixture-token"}}}"#
        case "/llu/connections":
            let entry = scenario == .noReading ?
                #"{"patientId":"fixture-patient-01","firstName":"Alex","lastName":"Rivera"}"# :
                #"{"patientId":"fixture-patient-01","firstName":"Alex","lastName":"Rivera","glucoseMeasurement":{"FactoryTimestamp":"02/18/2026 11:55:00 AM","Timestamp":"02/18/2026 11:55:00 AM","ValueInMgPerDl":112,"isHigh":false,"isLow":false}}"#
            let profiles = scenario == .noProfiles || scenario == .missingProfile ? "" :
                entry + (scenario == .multipleProfiles ? "," + #"{"patientId":"fixture-patient-02","firstName":"Blair","lastName":"Rivera","glucoseMeasurement":{"FactoryTimestamp":"02/18/2026 11:50:00 AM","ValueInMgPerDl":105,"isHigh":false,"isLow":false}}"# : "")
            body = #"{"status":0,"data": ["# + profiles + "]}"
        case "/llu/connections/fixture-patient-01/graph", "/llu/connections/fixture-patient-02/graph":
            let patientID = request.url!.pathComponents[3]
            switch scenario {
            case .error: throw CloudError.network
            case .termsRequired: body = #"{"status":4}"#
            case .rateLimited: return HTTPResult(status: 429, data: Data())
            case .invalidCredentials: body = #"{"status":2}"#
            case .invalidResponse: body = "invalid"
            default:
                let times = ["11:20", "11:25", "11:30", "11:35", "11:40", "11:45", "11:50", "11:55"]
                let values = [105, 108, 110, 107, 109, 111, 114, 112]
                let history = scenario == .noReading ? [] : zip(times, values).map { time, value in
                    ["FactoryTimestamp": "02/18/2026 \(time):00 AM", "ValueInMgPerDl": value,
                     "isHigh": false, "isLow": false] as [String: Any]
                } + [["FactoryTimestamp": "02/18/2026 11:15:00 AM", "ValueInMgPerDl": 350,
                      "isHigh": true, "isLow": false]]
                let data = try JSONSerialization.data(withJSONObject: ["status": 0, "data": [
                    "connection": ["patientId": scenario == .wrongPatient ? "another-patient" : patientID],
                    "graphData": history]])
                return HTTPResult(status: 200, data: data)
            }
        default: throw CloudError.invalidResponse
        }
        return HTTPResult(status: 200, data: Data(body.utf8))
    }
}
struct SimulatorLaunchRouting: ViewModifier {
    @Binding var selectedTab: AppTab
    @Binding var showLogin: Bool
    @Binding var showSetup: Bool
    @State private var didRouteLaunch = false

    func body(content: Content) -> some View {
        content.onAppear(perform: routeLaunchScreen)
    }

    private func routeLaunchScreen() {
        guard !didRouteLaunch else { return }
        didRouteLaunch = true
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-scenario"),
              let index = arguments.firstIndex(of: "--ui-screen"),
              arguments.indices.contains(index + 1) else { return }
        switch arguments[index + 1] {
        case "home": selectedTab = .home
        case "information": selectedTab = .information
        case "login": selectedTab = .home; showLogin = true
        case "setup": selectedTab = .home; showSetup = true
        default: break
        }
    }
}
#endif
