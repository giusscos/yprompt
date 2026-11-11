//
//  PlanPickerView.swift
//  yprompt
//

import SwiftUI
import StoreKit

/// What Pro adds, shared by the paywall and the onboarding Pro page.
/// Everything listed here is locked for free users; anything free stays off this list.
struct ProFeatureList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            #if !os(macOS)
            row("sparkles.rectangle.stack.fill", .orange, "No yPrompt Mark", "Save your videos without the \"Made with yPrompt\" mark.")
            #endif
            row("mic.fill",          .purple, "Voice Scroll",         "Follows your words as you speak and waits when you pause.")
            row("music.note.list",   .green,  "Lyrics Style",         "Every word lights up as you read, like song lyrics.")
            row("timer",             .teal,   "Timed Mode",           "Paces your script to finish right on time.")
            row("doc.fill",          .blue,   "Unlimited Scripts",    "No cap on how many you can create.")
            row("camera.fill",       .indigo, "Mac Notch Teleprompter", "Read from the notch, right next to your Mac's camera.")
            row("appletvremote.gen4.fill", .gray, "iPhone Remote",    "Control your Mac teleprompter from your iPhone.")
            row("paintpalette.fill", .pink,   "Custom Colors",        "Any text and background color you like.")
            row("sparkles",          .yellow, "All Future Pro Features", "New Pro features are included in every plan.")
        }
    }

    private func row(_ icon: String, _ color: Color, _ title: LocalizedStringKey, _ description: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

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

    /// On the accent-tinted glass of iOS / macOS 26 only white stays readable.
    private func onCard(_ isSelected: Bool, default style: some ShapeStyle) -> AnyShapeStyle {
        if #available(iOS 26.0, macOS 26.0, *), isSelected { return AnyShapeStyle(.white) }
        return AnyShapeStyle(style)
    }

    private func planCard(_ product: Product, subtitle: Text, badge: Text?) -> some View {
        let isSelected = selectedID == product.id
        return Button {
            selectedID = product.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(onCard(isSelected, default: isSelected ? .primary : .secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.headline)
                        .foregroundStyle(onCard(isSelected, default: .primary))
                    subtitle
                        .font(.caption)
                        .foregroundStyle(onCard(isSelected, default: .secondary))
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.title3.bold())
                    .foregroundStyle(onCard(isSelected, default: .primary))
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
