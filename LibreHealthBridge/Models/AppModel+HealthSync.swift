import BridgeCore
import Foundation

extension AppModel {
    @discardableResult
    func confirmPreview() async -> Bool {
        return await perform {
            guard canConfirmPreview, var saved = session,
                let id = saved.selectedPatientID
            else { throw LocalError.noReadings }
            saved.verifiedPatientID = id
            try sessionStore.save(saved)
            session = saved
        } == .success
    }

    @discardableResult
    func revokePreviewConfirmation() async -> Bool {
        return await perform {
            guard var saved = session, saved.verifiedPatientID != nil else { return }
            saved.verifiedPatientID = nil
            saved.syncPaused = true
            saved.resetAutomaticSyncConsent()
            try sessionStore.save(saved)
            session = saved
            reconcileAutomatic()
        } == .success
    }

    @discardableResult
    func authorizeHealth() async -> Bool {
        return await perform {
            guard isVerified else { throw LocalError.validationRequired }
            defer { refreshHealthAccess() }
            try await health.authorize()
        } == .success
    }

    @discardableResult
    func stopHealthSync() async -> Bool {
        return await perform {
            guard var saved = session else { return }
            saved.syncPaused = true
            saved.resetAutomaticSyncConsent()
            try sessionStore.save(saved)
            session = saved
            reconcileAutomatic()
        } == .success
    }

    // Home presents the destination, but the model owns whether an import or a
    // persisted pause must precede it. Failed persistence must not open setup.
    func primaryHealthAction() async -> PrimaryHealthAction {
        guard isSignedIn, !isBusy else { return .stay }
        refreshHealthAccess()
        if isHealthSyncActive {
            return await sync() == .success ? .syncSucceeded : .stay
        }
        if isVerified && session?.syncPaused == false {
            guard await stopHealthSync() else { return .stay }
        }
        return .openSetup
    }

    @discardableResult
    func sync(starting: Bool = false, background: Bool = false) async -> OperationOutcome {
        let result = await perform {
            guard isVerified else { throw LocalError.validationRequired }
            guard starting || session?.syncPaused == false else {
                throw LocalError.syncPaused
            }
            refreshHealthAccess()
            guard healthAccess == .authorized else {
                throw HealthError.permission
            }
            if background {
                guard ownership == .owned, protectedDataAvailable(),
                    session?.automaticEnabled == true, session?.automaticAttention == false
                else { throw CancellationError() }
            }
            if !background {
                guard canStartHealthSync else { throw CloudError.missingConnection }
            }
            // Always fetch fresh cloud data; never import an old preview after an error.
            try await fetchPreview(persistStatus: false)
            if background {
                ownership = await premium.ownership()
                refreshHealthAccess()
                guard ownership == .owned, protectedDataAvailable(),
                    session?.automaticEnabled == true, session?.automaticAttention == false,
                    isHealthSyncActive else { throw CancellationError() }
            }
            guard let snapshot, var saved = session,
                saved.selectedPatientID == snapshot.patientID
            else { throw CloudError.missingConnection }
            guard saved.verifiedPatientID == snapshot.patientID else {
                throw LocalError.validationRequired
            }
            saved.lastSync = try await health.write(
                snapshot,
                verifiedPatientID: saved.verifiedPatientID
            )
            if starting { saved.syncPaused = false }
            do {
                if !background && saved.automaticEnabled {
                    saved.automaticEarliest = max(
                        max(now(), saved.lastSync ?? now())
                            .addingTimeInterval(TimeInterval(saved.automaticInterval * 60)),
                        saved.automaticBackoffUntil ?? .distantPast
                    )
                }
                try sessionStore.save(saved)
                session = saved
                if !background { reconcileAutomatic() }
            } catch {
                // Do not enable sync when setup could not be saved.
                if starting { saved.syncPaused = true }
                session = saved
                errorMessage = safeMessage(LocalError.statusNotSaved)
            }
        }
        if !background, let retry = backgroundRetryAfter, var saved = session,
           saved.automaticEnabled {
            saved.automaticBackoffUntil = max(saved.automaticBackoffUntil ?? .distantPast, retry)
            saved.automaticEarliest = max(saved.automaticEarliest ?? .distantPast, retry)
            do {
                try sessionStore.save(saved)
                session = saved
                reconcileAutomatic()
            } catch { automaticMessage = "error.local.statusNotSaved" }
            backgroundRetryAfter = nil
        }
        return result == .success && errorMessage != nil
            ? .completedWithStorageWarning : result
    }
}
