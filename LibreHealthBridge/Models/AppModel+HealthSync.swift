import BridgeCore
import Foundation

extension AppModel {
    @discardableResult
    func confirmPreview() async -> Bool {
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
    func revokePreviewConfirmation() async -> Bool {
        return await perform {
            guard var saved = session, saved.verifiedPatientID != nil else { return }
            saved.verifiedPatientID = nil
            saved.syncPaused = true
            try sessionStore.save(saved)
            session = saved
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
            try sessionStore.save(saved)
            session = saved
        } == .success
    }

    @discardableResult
    func sync(starting: Bool = false) async -> OperationOutcome {
        let result = await perform {
            guard isVerified else { throw LocalError.validationRequired }
            guard starting || session?.syncPaused == false else {
                throw LocalError.syncPaused
            }
            refreshHealthAccess()
            guard healthAccess == .authorized else {
                throw HealthError.permission
            }
            guard selectedConnection != nil else { throw CloudError.missingConnection }
            // Always refetch the selected connection. Never import an old preview after an error.
            try await fetchPreview(persistStatus: false)
            guard let snapshot, var saved = session,
                saved.selectedPatientID == snapshot.patientID
            else { throw CloudError.missingConnection }
            saved.lastSync = try await health.write(
                snapshot,
                verifiedPatientID: saved.verifiedPatientID
            )
            if starting { saved.syncPaused = false }
            do {
                try sessionStore.save(saved)
                session = saved
            } catch {
                // Do not enable sync when setup could not be saved.
                if starting { saved.syncPaused = true }
                session = saved
                errorMessage = safeMessage(LocalError.statusNotSaved)
            }
        }
        return result == .success && errorMessage != nil
            ? .completedWithStorageWarning : result
    }
}
