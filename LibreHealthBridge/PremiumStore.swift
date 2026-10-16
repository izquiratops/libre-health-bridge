import StoreKit

// Reconcile this identifier with App Store Connect before shipping.
enum PremiumProduct {
    static let id = "com.jordi.librehealthbridge.premium"
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

// StoreKit verification and transaction handling stay independent of sync policy.
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
