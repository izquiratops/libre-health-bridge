import Foundation

// Consent, eligibility, and persisted retry policy. Both manual and background work
// still use the single import operation in AppModel+HealthSync.
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
}
