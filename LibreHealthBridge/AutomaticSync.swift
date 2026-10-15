import BackgroundTasks
import BridgeCore
import Foundation
import StoreKit
import UIKit

// Reconcile this identifier with App Store Connect before shipping.
enum PremiumProduct {
    static let id = "com.jordi.librehealthbridge.premium"
    static let refreshID = "com.jordi.librehealthbridge.refresh"
}

enum PremiumOwnership: Equatable {
    case owned, notOwned, unknown
}

enum PurchaseOutcome {
    case purchased, pending, cancelled
}

@MainActor
protocol PremiumStore {
    func ownership() async -> PremiumOwnership
    func price() async throws -> String
    func purchase() async throws -> PurchaseOutcome
    func restore() async throws
    func observe(_ changed: @escaping @MainActor () async -> Void)
}

@MainActor
final class StoreKitPremiumStore: PremiumStore {
    private var product: Product?
    private var updates: Task<Void, Never>?

    func ownership() async -> PremiumOwnership {
        var owned = false
        var unverified = false
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction) where transaction.productID == PremiumProduct.id:
                if transaction.revocationDate == nil { owned = true }
            case .unverified(let transaction, _) where transaction.productID == PremiumProduct.id:
                unverified = true
            default: break
            }
        }
        return owned ? .owned : (unverified ? .unknown : .notOwned)
    }

    func price() async throws -> String {
        let product = try await loadProduct()
        return product.displayPrice
    }

    private func loadProduct() async throws -> Product {
        if let product { return product }
        guard let item = try await Product.products(for: [PremiumProduct.id]).first else {
            throw PremiumError.unavailable
        }
        product = item
        return item
    }

    func purchase() async throws -> PurchaseOutcome {
        switch try await loadProduct().purchase() {
        case .success(.verified(let transaction)):
            guard transaction.productID == PremiumProduct.id, transaction.revocationDate == nil else {
                throw PremiumError.unverified
            }
            await transaction.finish()
            return .purchased
        case .success(.unverified): throw PremiumError.unverified
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw PremiumError.unavailable
        }
    }

    func restore() async throws { try await AppStore.sync() }

    func observe(_ changed: @escaping @MainActor () async -> Void) {
        guard updates == nil else { return }
        updates = Task {
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction) where transaction.productID == PremiumProduct.id:
                    await changed()
                    await transaction.finish()
                case .unverified(let transaction, _) where transaction.productID == PremiumProduct.id:
                    await changed() // Unknown ownership must not enable background imports.
                default: break
                }
            }
        }
    }
}

enum PremiumError: Error {
    case unavailable, unverified
}

@MainActor
protocol RefreshScheduler {
    func replace(earliest: Date?) throws
}

struct SystemRefreshScheduler: RefreshScheduler {
    func replace(earliest: Date?) throws {
        let scheduler = BGTaskScheduler.shared
        scheduler.cancel(taskRequestWithIdentifier: PremiumProduct.refreshID)
        guard let earliest else { return }
        let request = BGAppRefreshTaskRequest(identifier: PremiumProduct.refreshID)
        request.earliestBeginDate = earliest
        try scheduler.submit(request)
    }
}

// The system can call the handler on a cold background launch, before any scene appears.
// Registration is made in the App initializer, not from a view's .task.
// Expiration and the async operation can finish on different executors.
final class RefreshCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let complete: @Sendable (Bool) -> Void
    private enum State { case pending, reserved, completed }
    private var state: State = .pending
    init(_ complete: @escaping @Sendable (Bool) -> Void) { self.complete = complete }
    @discardableResult func finish(_ success: Bool) -> Bool {
        lock.lock()
        let shouldComplete = state == .pending
        if shouldComplete { state = .completed }
        lock.unlock()
        if shouldComplete { complete(success) }
        return shouldComplete
    }
    func reserveExpiration() -> Bool {
        lock.lock()
        let reserved = state == .pending
        if reserved { state = .reserved }
        lock.unlock()
        return reserved
    }
    func finishExpiration() {
        lock.lock()
        let shouldComplete = state == .reserved
        if shouldComplete { state = .completed }
        lock.unlock()
        if shouldComplete { complete(false) }
    }
}

private struct SendableRefreshTask: @unchecked Sendable {
    let value: BGAppRefreshTask
}

enum BackgroundRefresh {
    static func register(_ handler: @escaping @MainActor (BGAppRefreshTask) async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: PremiumProduct.refreshID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let boxed = SendableRefreshTask(value: task)
            Task { @MainActor in await handler(boxed.value) }
        }
    }
}

extension AppModel {
    var automaticStatus: String {
        guard session?.automaticEnabled == true else { return "automatic.off" }
        if session?.automaticAttention == true || !isHealthSyncActive { return "automatic.attention" }
        if ownership != .owned || !protectedDataAvailable() { return "automatic.deferred" }
        if !backgroundRefreshAvailable() { return "automatic.refreshUnavailable" }
        if session?.automaticDeferred == true { return "automatic.deferred" }
        return "automatic.enabledStatus"
    }

    var canEnableAutomatic: Bool {
        ownership == .owned && isHealthSyncActive && !isBusy
    }

    func startPremiumObservation() async {
        premium.observe { [weak self] in await self?.refreshPremium() }
        await refreshPremium()
        do { premiumPrice = try await premium.price() }
        catch { premiumPrice = nil } // A product load failure is not proof of revocation.
    }

    func refreshPremium() async {
        ownership = await premium.ownership()
        if ownership == .notOwned && session?.automaticEnabled == true && !isBusy {
            await setAutomaticEnabled(false)
        } else {
            reconcileAutomatic()
        }
    }

    func buyPremium() async {
        guard !isPremiumBusy else { return }
        isPremiumBusy = true
        defer { isPremiumBusy = false }
        do {
            switch try await premium.purchase() {
            case .purchased:
                automaticMessage = nil
                await refreshPremium()
            case .pending: automaticMessage = "automatic.pending"
            case .cancelled: automaticMessage = nil
            }
        } catch { automaticMessage = "automatic.purchaseFailed" }
    }

    func restorePremium() async {
        guard !isPremiumBusy else { return }
        isPremiumBusy = true
        defer { isPremiumBusy = false }
        do { try await premium.restore(); await refreshPremium(); automaticMessage = nil }
        catch { automaticMessage = "automatic.restoreFailed" }
    }

    func setAutomaticEnabled(_ enabled: Bool) async {
        guard var saved = session, !isBusy else { return }
        if enabled {
            refreshHealthAccess()
            guard canEnableAutomatic else { automaticMessage = "automatic.setupRequired"; return }
        }
        saved.resetAutomaticSyncConsent()
        if enabled {
            saved.automaticEnabled = true
            saved.automaticEarliest = now().addingTimeInterval(TimeInterval(saved.automaticInterval * 60))
        }
        do {
            try sessionStore.save(saved)
            session = saved
            automaticMessage = nil
            reconcileAutomatic()
        } catch {
            automaticMessage = "error.local.statusNotSaved"
            reconcileAutomatic() // Keep scheduling aligned with the state that actually persisted.
        }
    }

    func setAutomaticInterval(_ minutes: Int) {
        guard [15, 30, 60].contains(minutes), var saved = session, !isBusy else { return }
        saved.automaticInterval = minutes
        if saved.automaticEnabled {
            saved.automaticEarliest = max(
                saved.automaticBackoffUntil ?? .distantPast,
                max(now(), saved.lastSync ?? now()).addingTimeInterval(TimeInterval(minutes * 60))
            )
        }
        do {
            try sessionStore.save(saved)
            session = saved
            reconcileAutomatic()
        } catch {
            automaticMessage = "error.local.statusNotSaved"
            reconcileAutomatic()
        }
    }

    func reconcileAutomatic() {
        let eligible = session?.automaticEnabled == true && ownership == .owned
            && session?.automaticAttention == false
            && session?.selectedPatientID != nil
            && session?.verifiedPatientID == session?.selectedPatientID
            && session?.syncPaused == false && healthAccess == .authorized
        do {
            try scheduler.replace(earliest: eligible
                ? (session?.automaticEarliest ?? now().addingTimeInterval(1800)) : nil)
        } catch { automaticMessage = "automatic.deferred" }
    }

    func automaticAttemptFinished(_ result: OperationOutcome, failure: AutomaticSyncFailure? = nil) {
        guard var saved = session, saved.automaticEnabled else { reconcileAutomatic(); return }
        let interval = TimeInterval(saved.automaticInterval * 60)
        if result == .success { automaticMessage = nil }
        if result == .completedWithStorageWarning { automaticMessage = "error.local.statusNotSaved" }
        let delay: TimeInterval = result == .success ? interval : max(interval, 60 * 60)
        saved.automaticDeferred = result != .success
        saved.automaticBackoffUntil = result == .success ? nil :
            max(now().addingTimeInterval(delay), backgroundRetryAfter ?? .distantPast)
        saved.automaticEarliest = max(now().addingTimeInterval(interval), saved.automaticBackoffUntil ?? .distantPast)
        backgroundRetryAfter = nil
        let needsSetup = failure?.requiresSetup == true || healthAccess == .denied
        if needsSetup { saved.syncPaused = true }
        if needsSetup || failure?.requiresAttention == true {
            saved.automaticAttention = true
        }
        do {
            try sessionStore.save(saved)
            session = saved
            reconcileAutomatic()
        } catch {
            automaticMessage = "error.local.statusNotSaved"
            // Without durable backoff, do not immediately resubmit an overdue request.
            try? scheduler.replace(earliest: now().addingTimeInterval(max(interval, 3600)))
        }
    }

    // A manual operation owns session state until it finishes. Do not save an older
    // session over its in-flight fetch; persist the deferral in perform's cleanup.
    func deferBusyBackgroundAttempt() {
        guard session?.automaticEnabled == true else { reconcileAutomatic(); return }
        let interval = TimeInterval((session?.automaticInterval ?? 30) * 60)
        let later = now().addingTimeInterval(max(interval, 3600))
        busyBackgroundUntil = max(busyBackgroundUntil ?? .distantPast, later)
        try? scheduler.replace(earliest: busyBackgroundUntil)
    }

    func finishBusyBackgroundDeferral() {
        guard let later = busyBackgroundUntil else { return }
        busyBackgroundUntil = nil
        guard var saved = session, saved.automaticEnabled else { reconcileAutomatic(); return }
        saved.automaticDeferred = true
        saved.automaticBackoffUntil = max(saved.automaticBackoffUntil ?? .distantPast, later)
        saved.automaticEarliest = max(saved.automaticEarliest ?? .distantPast, later)
        do {
            try sessionStore.save(saved)
            session = saved
            reconcileAutomatic()
        } catch {
            automaticMessage = "error.local.statusNotSaved"
            try? scheduler.replace(earliest: later)
        }
    }

    // No preview download during background restoration. A callback while active never imports.
    func backgroundAttempt() async -> OperationOutcome {
        guard !isBusy else {
            deferBusyBackgroundAttempt()
            return .busy
        }
        backgroundFailure = nil
        backgroundRetryAfter = nil
        if session == nil {
            guard protectedDataAvailable() else {
                try? scheduler.replace(earliest: now().addingTimeInterval(3600))
                automaticMessage = "automatic.deferred"
                return .failure
            }
            do {
                guard let saved = try sessionStore.load() else { reconcileAutomatic(); return .failure }
                session = saved
                api = makeClient(saved.credentials)
                // The import path will fetch fresh connections and the graph once.
            } catch {
                // A Keychain load error can be transient protection, not logout.
                try? scheduler.replace(earliest: now().addingTimeInterval(3600))
                automaticMessage = "automatic.deferred"
                return .failure
            }
        }
        ownership = await premium.ownership()
        if ownership == .notOwned && session?.automaticEnabled == true {
            await setAutomaticEnabled(false)
            return .failure
        }
        refreshHealthAccess()
        guard protectedDataAvailable(), ownership == .owned,
            session?.automaticEnabled == true, session?.automaticAttention == false,
            session?.selectedPatientID != nil,
            session?.verifiedPatientID == session?.selectedPatientID,
            session?.syncPaused == false, healthAccess == .authorized
        else {
            let failure: AutomaticSyncFailure? = ownership == .owned && protectedDataAvailable()
                && session?.automaticEnabled == true &&
                (session?.verifiedPatientID != session?.selectedPatientID ||
                 session?.selectedPatientID == nil || session?.syncPaused != false ||
                 healthAccess != .authorized)
                ? .confirmationRequired : nil
            automaticAttemptFinished(.failure, failure: failure)
            return .failure
        }
        guard now() >= (session?.automaticEarliest ?? .distantFuture) else {
            reconcileAutomatic()
            return .failure
        }
        let result = await sync(background: true)
        if ownership == .notOwned { await setAutomaticEnabled(false) }
        automaticAttemptFinished(result, failure: backgroundFailure)
        backgroundFailure = nil
        return result
    }

    func handleBackgroundTask(_ task: BGAppRefreshTask) async {
        // An active app remains manual-only, even if iOS delivers a stale callback.
        guard UIApplication.shared.applicationState == .background else {
            automaticAttemptFinished(.cancelled)
            task.setTaskCompleted(success: false)
            return
        }
        let boxed = SendableRefreshTask(value: task)
        let completion = RefreshCompletion { boxed.value.setTaskCompleted(success: $0) }
        let work = Task { await backgroundAttempt() }
        task.expirationHandler = { [weak self] in
            guard completion.reserveExpiration() else { return }
            work.cancel()
            Task { @MainActor in
                // Submit the later opportunity before telling iOS this task is done.
                self?.automaticAttemptFinished(.cancelled)
                completion.finishExpiration()
            }
        }
        let outcome = await work.value
        task.expirationHandler = nil
        completion.finish(outcome == .success || outcome == .completedWithStorageWarning)
    }
}
