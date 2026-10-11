import BridgeCore
import Foundation
import Observation
import UIKit

enum OperationOutcome: Equatable {
    case success, completedWithStorageWarning, cancelled, busy, failure
}

enum PrimaryHealthAction {
    case openSetup, syncSucceeded, stay
}

enum RestorationState {
    case idle, loading, loaded, retryableFailure
}

protocol CloudAPI: Sendable {
    func connections() async throws -> [Connection]
    func snapshot(for connection: Connection, now: Date?) async throws -> CloudSnapshot
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
    var ownership: PremiumOwnership = .unknown
    var premiumPrice: String?
    var isPremiumBusy = false
    var automaticMessage: String?
    var backgroundFailure: String?
    var backgroundRetryAfter: Date?

    @ObservationIgnored let sessionStore: any SessionStore
    @ObservationIgnored let health: any GlucoseWriter
    @ObservationIgnored let makeClient: (Credentials) -> any CloudAPI
    @ObservationIgnored var api: (any CloudAPI)?
    @ObservationIgnored let premium: any PremiumStore
    @ObservationIgnored let scheduler: any RefreshScheduler
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let protectedDataAvailable: () -> Bool
    @ObservationIgnored let backgroundRefreshAvailable: () -> Bool
    @ObservationIgnored var busyBackgroundUntil: Date?

    init(
        sessionStore: any SessionStore = KeychainStore(),
        health: any GlucoseWriter = HealthWriter(),
        makeClient: @escaping (Credentials) -> any CloudAPI = {
            LibreCloudClient(credentials: $0)
        },
        premium: any PremiumStore = StoreKitPremiumStore(),
        scheduler: any RefreshScheduler = SystemRefreshScheduler(),
        now: @escaping () -> Date = Date.init,
        protectedDataAvailable: @escaping () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
        backgroundRefreshAvailable: @escaping () -> Bool = {
            UIApplication.shared.backgroundRefreshStatus == .available
        }
    ) {
        self.sessionStore = sessionStore
        self.health = health
        self.makeClient = makeClient
        self.premium = premium
        self.scheduler = scheduler
        self.now = now
        self.protectedDataAvailable = protectedDataAvailable
        self.backgroundRefreshAvailable = backgroundRefreshAvailable
    }

    var isSignedIn: Bool { session != nil }
    var selectedPatientID: String? { session?.selectedPatientID }
    var selectedConnection: Connection? {
        connections.first { $0.patientId == selectedPatientID }
    }
    var isVerified: Bool {
        guard let selectedPatientID else { return false }
        return session?.verifiedPatientID == selectedPatientID
    }

    // Confirmation is tied to the displayed, current preview of the selected patient.
    // Import is different: it refetches, so a stale display does not block a confirmed profile.
    var canConfirmPreview: Bool {
        guard let selected = selectedConnection else { return false }
        return isPreviewCurrent && snapshot?.patientID == selected.patientId
            && snapshot?.preview?.canValidate == true
    }

    var canStartHealthSync: Bool {
        selectedConnection != nil && isVerified && healthAccess == .authorized
    }

    var isHealthSyncActive: Bool {
        canStartHealthSync && session?.syncPaused == false
    }

    var healthSyncStatus: String {
        if selectedConnection == nil { return "health.sync.profileMissing" }
        if !isVerified { return "checklist.sync.inactive" }
        if healthAccess != .authorized { return "health.sync.permissionOff" }
        if session?.syncPaused == true { return "health.sync.paused" }
        return "health.sync.working"
    }

    func refreshHealthAccess() {
        healthAccess = health.access
    }
}
