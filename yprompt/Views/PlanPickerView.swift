//
//  PlanPickerView.swift
//  yprompt
//

import SwiftUI
import StoreKit

/// Selectable plan cards shared by the paywall and the onboarding Pro page.
/// Yearly (with its free trial) is listed first and pre-selected; Lifetime is last.
struct PlanPicker: View {
    @Binding var selectedID: String
    @Environment(StoreKitService.self) private var storeKit

    var body: some View {
        VStack(spacing: 10) {
            if let p = storeKit.yearlyProduct {
                planCard(p, subtitle: perWeekText(p), badge: yearlyBadge)
            }
            if let p = storeKit.weeklyProduct {
                planCard(p, subtitle: Text(p.description), badge: nil)
            }
            if let p = storeKit.lifetimeProduct {
                planCard(p, subtitle: Text(p.description), badge: nil)
            }
        }
    }

    private var yearlyBadge: Text {
        if let days = storeKit.yearlyTrialDays {
            Text("\(days) Days Free")
        } else {
            Text("Best Value")
        }
    }

    private func perWeekText(_ product: Product) -> Text {
        let perWeek = (product.price / 52).formatted(product.priceFormatStyle)
        return Text("Just \(perWeek) per week")
    }

    private func planCard(_ product: Product, subtitle: Text, badge: Text?) -> some View {
        let isSelected = selectedID == product.id
        return Button {
            selectedID = product.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName).font(.headline)
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(product.displayPrice).font(.title3.bold())
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .ypGlassEffect(cornerRadius: 14, highlighted: isSelected)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    badge
                        .font(.caption2.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.yellow, in: Capsule())
                        .offset(x: -10, y: -10)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Primary call to action for the plan chosen in `PlanPicker`, with the trial terms underneath.
struct PlanPurchaseButton: View {
    let selectedID: String
    var onError: (Error) -> Void = { _ in }

    @Environment(\.purchase) private var purchase
    @Environment(StoreKitService.self) private var storeKit
    @State private var isPurchasing = false

    private var product: Product? { storeKit.products.first { $0.id == selectedID } }

    private var trialDays: Int? {
        selectedID == AppConstants.yearlySubscriptionID ? storeKit.yearlyTrialDays : nil
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                guard let product else { return }
                Task {
                    isPurchasing = true
                    do {
                        try await storeKit.purchase(product) { try await purchase($0) }
                    } catch {
                        onError(error)
                    }
                    isPurchasing = false
                }
            } label: {
                Group {
                    if isPurchasing {
                        ProgressView()
                    } else if let trialDays {
                        Text("Start \(trialDays)-Day Free Trial")
                    } else {
                        Text("Continue")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .ypGlassProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .tint(Color.accentColor)
            .disabled(product == nil || isPurchasing)

            if let trialDays, let product {
                Text("\(trialDays) days free, then \(product.displayPrice)/year. Cancel anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
