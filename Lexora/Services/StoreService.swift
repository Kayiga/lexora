import StoreKit
import Foundation
import CryptoKit
import Observation

/// Manages the one-time premium unlock via StoreKit 2.
/// Product ID: com.yiga.Lexora.premium (non-consumable, $4.99)
///
/// Access model:
///   isUnlocked = isPremium || isInFreeTrial || promoUnlocked
///   - First 60 days after install → all premium features free
///   - After 60 days → paywall appears; $4.99 unlocks forever
///   - Promo code → permanent unlock, no payment required
@Observable @MainActor
final class StoreService {

    // MARK: - Constants

    static let premiumProductID  = "com.yiga.Lexora.premium"
    static let trialDurationDays = 60
    private static let installDateKey  = "lexora.installDate"
    private static let promoUnlockedKey = "lexora.promoUnlocked"

    /// SHA-256 of the promo code (case-insensitive, trimmed).
    /// To change the code: run  python3 -c "import hashlib; print(hashlib.sha256(b'YOUR-CODE'.lower().encode()).hexdigest())"
    /// Current code: LEXORA-VIP-2026
    private static let promoCodeHash = "3b53f9812cfc0d8c8fb748332b568cc4feca459e464f68d4f2ebd62702118453"

    // MARK: - State

    /// Whether the user holds a verified paid premium entitlement.
    var isPremium: Bool = false
    /// The fetched product (nil until loaded, or in simulator without StoreKit config).
    var premiumProduct: Product? = nil
    /// True while a purchase or restore is in flight.
    var purchaseInProgress: Bool = false
    /// Localised error from the last failed purchase/restore.
    var purchaseError: String? = nil
    /// True once the initial entitlement check has completed.
    var entitlementChecked: Bool = false

    // MARK: - Promo code unlock

    /// Permanently true once a valid promo code has been redeemed.
    /// Stored in UserDefaults so it survives app restarts.
    var promoUnlocked: Bool = false {
        didSet { UserDefaults.standard.set(promoUnlocked, forKey: Self.promoUnlockedKey) }
    }

    /// Result type for redeemCode(_:)
    enum RedeemResult {
        case success          // correct code, just unlocked
        case alreadyUnlocked  // correct code, was already redeemed
        case invalid          // wrong code
    }

    /// Validates `code` against the stored SHA-256 hash.
    /// Comparison is case-insensitive and trims surrounding whitespace.
    /// Returns `.success` on first valid redemption, `.alreadyUnlocked` if already redeemed.
    @discardableResult
    func redeemCode(_ code: String) -> RedeemResult {
        let normalised = code.trimmingCharacters(in: .whitespaces).lowercased()
        let digest     = SHA256.hash(data: Data(normalised.utf8))
        let hex        = digest.map { String(format: "%02x", $0) }.joined()

        guard hex == Self.promoCodeHash else { return .invalid }
        if promoUnlocked { return .alreadyUnlocked }
        promoUnlocked = true
        return .success
    }

    // MARK: - Trial

    /// Date the app was first launched. Written once; never changes.
    private(set) var installDate: Date

    /// True if the 60-day free trial is currently active.
    var isInFreeTrial: Bool {
        guard !isPremium else { return false }   // paid users don't need the trial flag
        return trialDaysRemaining > 0
    }

    /// Calendar days left in the free trial (0 when expired or paid).
    var trialDaysRemaining: Int {
        guard !isPremium else { return 0 }
        let elapsed = Calendar.current.dateComponents(
            [.day], from: installDate, to: Date()
        ).day ?? Self.trialDurationDays
        return max(0, Self.trialDurationDays - elapsed)
    }

    /// **Single source of truth for feature access.**
    /// True when the user has paid, is in the 60-day trial, or redeemed a promo code.
    var isUnlocked: Bool {
        #if DEBUG
        return true   // always unlocked in debug / TestFlight
        #else
        return isPremium || isInFreeTrial || promoUnlocked
        #endif
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        // Restore promo-unlock state from previous launch
        promoUnlocked = defaults.bool(forKey: Self.promoUnlockedKey)

        // Record install date the very first time the app launches.
        if let stored = defaults.object(forKey: Self.installDateKey) as? Date {
            installDate = stored
        } else {
            let now = Date()
            defaults.set(now, forKey: Self.installDateKey)
            installDate = now
        }

        Task {
            await loadProducts()
            await refreshEntitlement()
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
