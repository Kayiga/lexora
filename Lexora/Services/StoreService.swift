import StoreKit
import Foundation
import Observation

/// Manages the one-time premium unlock via StoreKit 2.
/// Product ID: com.yiga.Lexora.premium (non-consumable, $4.99)
@Observable @MainActor
final class StoreService {

    // MARK: - Constants

    static let premiumProductID = "com.yiga.Lexora.premium"

    // MARK: - State

    /// Whether the user currently holds a verified premium entitlement.
    var isPremium: Bool = false
    /// The fetched product (nil until loaded, or in simulator without StoreKit config).
    var premiumProduct: Product? = nil
    /// True while a purchase or restore is in flight.
    var purchaseInProgress: Bool = false
    /// Localised error from the last failed purchase/restore.
    var purchaseError: String? = nil
    /// True once the initial entitlement check has completed.
    var entitlementChecked: Bool = false

    // MARK: - Init

    init() {
        Task {
            await loadProducts()
            await refreshEntitlement()
            // Start listening for external transaction updates (e.g. family sharing, refunds)
            listenForTransactionUpdates()
        }
    }

    // MARK: - Product loading

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [Self.premiumProductID])
            premiumProduct = products.first
        } catch {
            // Unavailable in Simulator without a StoreKit config file — handled gracefully.
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product = premiumProduct else { return }
        purchaseInProgress = true
        purchaseError = nil
        defer { purchaseInProgress = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPremium = true
            case .userCancelled:
                break
            case .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Restore

    func restore() async {
        purchaseInProgress = true
        purchaseError = nil
        defer { purchaseInProgress = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Entitlement check

    func refreshEntitlement() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               tx.productID == Self.premiumProductID,
               tx.revocationDate == nil {
                found = true
                break
            }
        }
        isPremium = found
        entitlementChecked = true

        // Debug / TestFlight / Simulator: always unlock so the app is usable during development.
        #if DEBUG
        isPremium = true
        entitlementChecked = true
        #endif
    }

    // MARK: - Transaction listener

    private func listenForTransactionUpdates() {
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let tx) = result {
                    await MainActor.run {
                        if tx.productID == Self.premiumProductID && tx.revocationDate == nil {
                            self.isPremium = true
                        } else if tx.revocationDate != nil {
                            // Refund received
                            Task { await self.refreshEntitlement() }
                        }
                    }
                    await tx.finish()
                }
            }
        }
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let value):      return value
        }
    }
}
