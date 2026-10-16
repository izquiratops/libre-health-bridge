import BridgeCore
import Foundation
import HealthKit

enum HealthAccess: String {
    case unavailable = "health.access.unavailable"
    case notRequested = "health.access.notRequested"
    case denied = "health.access.denied"
    case authorized = "health.access.authorized"
}

enum HealthError: Error, LocalizedError {
    case unavailable, permission, query, save
    var errorDescription: String? {
        switch self {
        case .unavailable: "error.health.unavailable"
        case .permission: "error.health.permission"
        case .query: "error.health.query"
        case .save: "error.health.save"
        }
    }
}

@MainActor
protocol GlucoseHealthStore {
    var access: HealthAccess { get }
    func authorize() async throws
    func existingSamples(for readings: [GlucoseReading]) async throws -> [StoredReading]
    func save(_ samples: [HKQuantitySample]) async throws
}

@MainActor
protocol GlucoseWriter {
    var access: HealthAccess { get }
    func authorize() async throws
    func write(_ snapshot: CloudSnapshot, verifiedPatientID: String?) async throws -> Date
}

@MainActor
final class HealthWriter: GlucoseWriter {
    private let backend: any GlucoseHealthStore
    private let glucose = HKQuantityType(.bloodGlucose)
    private let unit = HKUnit(from: "mg/dL")

    init(backend: any GlucoseHealthStore = SystemHealthStore()) { self.backend = backend }
    var access: HealthAccess { backend.access }

    func authorize() async throws {
        try await backend.authorize()
        // A completed authorization sheet does not mean the user granted permission.
        guard access == .authorized else { throw HealthError.permission }
    }

    func write(_ snapshot: CloudSnapshot, verifiedPatientID: String?) async throws -> Date {
        guard verifiedPatientID == snapshot.patientID else { throw LocalError.validationRequired }
        guard access != .unavailable else { throw HealthError.unavailable }
        guard access == .authorized else { throw HealthError.permission }
        try Task.checkCancellation()
        let existing = try await backend.existingSamples(for: snapshot.batch.readings)
        try Task.checkCancellation()
        let plan = try ImportPlanner.plan(readings: snapshot.batch.readings, existing: existing)
        let samples = plan.writes.map { write in
            HKQuantitySample(type: glucose, quantity: HKQuantity(unit: unit, doubleValue: write.reading.valueMgDl),
                             start: write.reading.timestamp, end: write.reading.timestamp,
                             metadata: [
                                 HKMetadataKeySyncIdentifier: write.reading.id,
                                 HKMetadataKeySyncVersion: write.version,
                                 HKMetadataKeyWasUserEntered: false,
                                 "org.librehealthbridge.source": "LibreLinkUp cloud import",
                                 "org.librehealthbridge.measurementKind": "Interstitial glucose"
                             ])
        }
        // Once a save starts, it may finish despite cancellation. Return its completion time.
        if !samples.isEmpty { try Task.checkCancellation(); try await backend.save(samples) }
        return Date()
    }
}

// Protects the single continuation against a query callback racing cancellation.
private final class SampleQueryState: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HKHealthStore
    private var query: HKSampleQuery?
    private var continuation: CheckedContinuation<[StoredReading], any Error>?
    private var cancelled = false

    init(store: HKHealthStore) { self.store = store }

    func start(_ query: HKSampleQuery, continuation: CheckedContinuation<[StoredReading], any Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.query = query
        self.continuation = continuation
        store.execute(query)
        lock.unlock()
    }

    func finish(_ result: Result<[StoredReading], any Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        query = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let query = self.query
        let continuation = self.continuation
        self.continuation = nil
        self.query = nil
        lock.unlock()
        if let query { store.stop(query) }
        continuation?.resume(throwing: CancellationError())
    }
}

@MainActor
final class SystemHealthStore: GlucoseHealthStore {
    private let store = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    private let glucose = HKQuantityType(.bloodGlucose)

    var access: HealthAccess {
        guard let store else { return .unavailable }
        switch store.authorizationStatus(for: glucose) {
        case .notDetermined: return .notRequested
        case .sharingDenied: return .denied
        case .sharingAuthorized: return .authorized
        @unknown default: return .unavailable
        }
    }

    func authorize() async throws {
        guard let store else { throw HealthError.unavailable }
        do {
            // No read permission for other sources. HealthKit exposes our own saved samples.
            try await store.requestAuthorization(toShare: [glucose], read: [])
        } catch is CancellationError { throw CancellationError() }
        catch { throw HealthError.permission }
    }

    func save(_ samples: [HKQuantitySample]) async throws {
        guard let store else { throw HealthError.unavailable }
        do { try await store.save(samples) }
        catch is CancellationError { throw CancellationError() }
        catch { throw HealthError.save }
    }

    func existingSamples(for readings: [GlucoseReading]) async throws -> [StoredReading] {
        guard let store else { throw HealthError.unavailable }
        guard let start = readings.map(\.timestamp).min(), let end = readings.map(\.timestamp).max() else { return [] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: start, end: end.addingTimeInterval(1), options: [.strictStartDate]),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier)
        ])
        let state = SampleQueryState(store: store)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(sampleType: glucose, predicate: predicate,
                                          limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                    guard error == nil, let samples = samples as? [HKQuantitySample] else {
                        state.finish(.failure(HealthError.query))
                        return
                    }
                    let unit = HKUnit(from: "mg/dL")
                    let result: [StoredReading] = samples.compactMap { sample in
                        guard let id = sample.metadata?[HKMetadataKeySyncIdentifier] as? String,
                              ReadingIdentity.recognizes(id) else { return nil }
                        let version = (sample.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue ?? 0
                        return StoredReading(id: id, valueMgDl: sample.quantity.doubleValue(for: unit), version: version)
                    }
                    state.finish(.success(result))
                }
                state.start(query, continuation: continuation)
            }
        } onCancel: {
            state.cancel()
        }
    }
}
