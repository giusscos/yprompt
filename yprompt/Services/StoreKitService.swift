//
//  StoreKitService.swift
//  yprompt
//

import Foundation
import StoreKit
import os

private let log = Logger(subsystem: "com.giusscos.yprompt", category: "StoreKit")

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
        Task {
            await refreshEntitlements()
            await loadProducts()
        }
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
            await updateYearlyTrialEligibility()
            await refreshEntitlements()
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
            log.info("Purchased \(Self.describe(transaction), privacy: .public)")
            if transaction.revocationDate == nil {
                purchasedProductIDs.insert(transaction.productID)
            }
            await transaction.finish()
        case .pending:
            // Ask to Buy or extra payment confirmation; the entitlement arrives later via Transaction.updates.
            throw StoreKitServiceError.pending
        case .userCancelled:
            break
        @unknown default:
            break
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
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

    /// Re-reads what the user owns. Independent of product loading, so Pro status is restored
    /// even when the product request fails; also called when the app becomes active.
    ///
    /// `Transaction.currentEntitlements` alone is not reliable: it has been seen returning nothing
    /// for an active, verified subscription. So the result is the union of three sources:
    /// current entitlements, each product's latest transaction, and the subscription group status.
    func refreshEntitlements() async {
        var purchased: Set<String> = []

        for await result in Transaction.currentEntitlements {
            if let t = try? checkVerified(result), t.revocationDate == nil {
                purchased.insert(t.productID)
            }
        }

        for id in Self.ownedProductIDs {
            guard let result = await Transaction.latest(for: id),
                  let t = try? checkVerified(result),
                  t.revocationDate == nil, !t.isUpgraded else { continue }
            if let expiration = t.expirationDate, expiration <= .now { continue }
            purchased.insert(t.productID)
        }

        // Covers billing retry and grace period, where the latest transaction may have expired.
        if let groupID = (yearlyProduct ?? weeklyProduct)?.subscription?.subscriptionGroupID,
           let statuses = try? await Product.SubscriptionInfo.status(for: groupID) {
            for status in statuses where [.subscribed, .inGracePeriod, .inBillingRetryPeriod].contains(status.state) {
                if let t = try? checkVerified(status.transaction), t.revocationDate == nil {
                    purchased.insert(t.productID)
                }
            }
        }

        log.info("Entitlements: \(purchased.sorted(), privacy: .public)")
        purchasedProductIDs = purchased
    }

    private static let ownedProductIDs = [
        AppConstants.lifetimeProductID,
        AppConstants.yearlySubscriptionID,
        AppConstants.weeklySubscriptionID,
        AppConstants.monthlySubscriptionID
    ]

    private static func describe(_ t: Transaction) -> String {
        "\(t.productID) id=\(t.id) env=\(t.environment.rawValue) purchased=\(t.purchaseDate) expires=\(t.expirationDate.map { "\($0)" } ?? "-") revoked=\(t.revocationDate.map { "\($0)" } ?? "-") upgraded=\(t.isUpgraded)"
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            log.error("Unverified transaction: \(error.localizedDescription, privacy: .public)")
            throw StoreKitServiceError.failedVerification
        case .verified(let value): return value
        }
    }

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                guard let transaction = try? await self.checkVerified(result) else { continue }
                await transaction.finish()
                // Renewals, refunds, Ask to Buy approvals and purchases made on other devices.
                await self.refreshEntitlements()
            }
        }
    }
}

enum StoreKitServiceError: LocalizedError {
    case failedVerification
    case pending

    var errorDescription: String? {
        switch self {
        case .failedVerification: String(localized: "Purchase verification failed.")
        case .pending: String(localized: "Your purchase is pending approval. Pro unlocks as soon as it's confirmed.")
        }
    }
}
