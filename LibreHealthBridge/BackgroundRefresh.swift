import BackgroundTasks
import Foundation
import UIKit

@MainActor
protocol RefreshScheduler {
    func replace(earliest: Date?) throws
}

struct SystemRefreshScheduler: RefreshScheduler {
    func replace(earliest: Date?) throws {
        let scheduler = BGTaskScheduler.shared
        scheduler.cancel(taskRequestWithIdentifier: BackgroundRefresh.identifier)
        guard let earliest else { return }
        let request = BGAppRefreshTaskRequest(identifier: BackgroundRefresh.identifier)
        request.earliestBeginDate = earliest
        try scheduler.submit(request)
    }
}

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

// The system can call the handler on a cold background launch, before any scene appears.
// Registration is made in the App initializer, not from a view's .task.
enum BackgroundRefresh {
    static let identifier = "com.jordi.librehealthbridge.refresh"

    static func register(_ handler: @escaping @MainActor (BGAppRefreshTask) async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let boxed = SendableRefreshTask(value: task)
            Task { @MainActor in await handler(boxed.value) }
        }
    }
}

// Coordinate system task lifetime here; AppModel+AutomaticSync owns eligibility and backoff.
extension AppModel {
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
