// Translate Premium operations into UI state and reconcile automatic-sync policy.
// Buying or restoring never opts the user into automatic imports.
extension AppModel {
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
}
