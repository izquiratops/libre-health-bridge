import BridgeCore
import Foundation

extension AppModel {
    func restore() async {
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
        if result == .success { reconcileAutomatic() }
    }

    func login(email: String, password: String) async -> Bool {
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
                    ? available[0].patientId : nil,
                syncPaused: true
            )
            try sessionStore.save(saved)
            session = saved
            reconcileAutomatic()
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
        _ = await perform {
            guard var saved = session, saved.selectedPatientID != id else {
                return
            }
            guard connections.contains(where: { $0.patientId == id }) else {
                throw CloudError.missingConnection
            }
            saved.selectedPatientID = id
            saved.verifiedPatientID = nil
            saved.syncPaused = true
            saved.lastSync = nil
            saved.resetAutomaticSyncConsent()
            isPreviewCurrent = false
            try sessionStore.save(saved)
            session = saved
            reconcileAutomatic()
            snapshot = nil
            try await fetchPreview(refreshConnections: false)
        }
    }

    func refresh() async {
        guard isSignedIn else {
            if restoration == .retryableFailure { await restore() }
            return
        }
        let result = await perform { try await fetchPreview() }
        if result == .success { restoration = .loaded }
        if result == .failure { restoration = .retryableFailure }
    }

    func logout() async {
        _ = await perform {
            // Clear the UI only after deletion succeeds, so failure cannot hide retained credentials.
            try sessionStore.delete()
            api = nil
            session = nil
            reconcileAutomatic()
            restoration = .idle
            connections = []
            snapshot = nil
            isPreviewCurrent = false
        }
    }

    func dismissError() { errorMessage = nil }

    func fetchPreview(
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

    func perform(_ operation: () async throws -> Void) async
        -> OperationOutcome
    {
        guard !isBusy else { return .busy }
        isBusy = true
        errorMessage = nil
        defer {
            isBusy = false
            refreshHealthAccess()
            finishBusyBackgroundDeferral()
            if ownership == .notOwned && session?.automaticEnabled == true {
                Task { await setAutomaticEnabled(false) }
            }
        }
        do {
            try await operation()
            return .success
        } catch is CancellationError { return .cancelled } catch {
            if case .rateLimitedUntil(let until) = error as? CloudError {
                backgroundRetryAfter = until
            }
            backgroundFailure = AutomaticSyncFailure(error)
            errorMessage = safeMessage(error)
            return .failure
        }
    }

    func safeMessage(_ error: any Error) -> String {
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
