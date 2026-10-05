//
//  StoreKitService.swift
//  yprompt
//

import Foundation
import StoreKit

@Observable @MainActor
class StoreKitService {
    var products: [Product] = []
    var purchasedProductIDs: Set<String> = []
    var isLoading = false
    var errorMessage: String?
    /// Length of the yearly plan's free trial, when this Apple ID is still eligible for it.
    var yearlyTrialDays: Int?

    @ObservationIgnored nonisolated(unsafe) private var transactionListener: Task<Void, Error>?

    init() {
        transactionListener = listenForTransactions()
        Task { await loadProducts() }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Computed State

    var isLifetimePurchased: Bool {
        purchasedProductIDs.contains(AppConstants.lifetimeProductID)
    }

    var isSubscribed: Bool {
        purchasedProductIDs.contains(AppConstants.weeklySubscriptionID) ||
        purchasedProductIDs.contains(AppConstants.yearlySubscriptionID) ||
        purchasedProductIDs.contains(AppConstants.monthlySubscriptionID) // legacy
    }

    var isPremium: Bool {
        #if DEBUG
        // Unlocks Pro for App Store screenshot captures: launch with `-ypDemoPro`.
        if ProcessInfo.processInfo.arguments.contains("-ypDemoPro") { return true }
        #endif
        return isLifetimePurchased || isSubscribed
    }

    var lifetimeProduct: Product? { products.first { $0.id == AppConstants.lifetimeProductID } }
    var weeklyProduct: Product? { products.first { $0.id == AppConstants.weeklySubscriptionID } }
    var yearlyProduct: Product? { products.first { $0.id == AppConstants.yearlySubscriptionID } }

    // MARK: - Load

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let ids: Set<String> = [
                AppConstants.lifetimeProductID,
                AppConstants.weeklySubscriptionID,
                AppConstants.yearlySubscriptionID
            ]
            products = try await Product.products(for: ids)
            await updatePurchasedProducts()
            await updateYearlyTrialEligibility()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Purchase

    /// Pass `@Environment(\.purchase)` as `perform` — required on visionOS, where
    /// `Product.purchase(options:)` is unavailable.
    func purchase(
        _ product: Product,
        perform: (Product) async throws -> Product.PurchaseResult
    ) async throws {
        let result = try await perform(product)
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            if transaction.revocationDate == nil {
                purchasedProductIDs.insert(transaction.productID)
            }
            await transaction.finish()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await updatePurchasedProducts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func updateYearlyTrialEligibility() async {
        guard let subscription = yearlyProduct?.subscription,
              let offer = subscription.introductoryOffer,
              offer.paymentMode == .freeTrial,
              await subscription.isEligibleForIntroOffer else {
            yearlyTrialDays = nil
            return
        }
        let value = offer.period.value
        switch offer.period.unit {
        case .day:   yearlyTrialDays = value
        case .week:  yearlyTrialDays = value * 7
        case .month: yearlyTrialDays = value * 30
        case .year:  yearlyTrialDays = value * 365
        @unknown default: yearlyTrialDays = nil
        }
    }

    private func updatePurchasedProducts() async {
        var purchased: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.revocationDate == nil {
                purchased.insert(transaction.productID)
            }
        }
        purchasedProductIDs = purchased
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified: throw StoreKitServiceError.failedVerification
        case .verified(let value): return value
        }
    }

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                guard let transaction = try? await self.checkVerified(result) else { continue }
                if transaction.revocationDate == nil {
                    _ = await MainActor.run { self.purchasedProductIDs.insert(transaction.productID) }
                } else {
                    await self.updatePurchasedProducts()
                }
                await transaction.finish()
            }
        }
    }
}

enum StoreKitServiceError: LocalizedError {
    case failedVerification

    var errorDescription: String? { "Purchase verification failed." }
}
