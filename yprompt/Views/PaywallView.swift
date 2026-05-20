//
//  PaywallView.swift
//  yprompt
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storeKit: StoreKitService

    @State private var isPurchasing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    featuresSection

                    if storeKit.isLoading {
                        ProgressView("Loading products…")
                            .padding()
                    } else {
                        productsSection
                    }

                    restoreButton
                    footerNote
                }
                .padding()
            }
            .navigationTitle("YPrompt Pro")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: storeKit.isPremium) { _, isPremium in
                if isPremium { dismiss() }
            }
            .alert("Purchase Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Unlock YPrompt Pro")
                .font(.largeTitle.bold())

            Text("Professional teleprompter tools for creators, speakers, and broadcasters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow("Unlimited Scripts",
                       icon: "doc.fill",
                       detail: "No limit on the number of scripts")
            featureRow("Custom Colors",
                       icon: "paintpalette.fill",
                       detail: "Full color picker for text & background")
            featureRow("iCloud Sync",
                       icon: "icloud.fill",
                       detail: "Access your scripts on all devices")
            featureRow("All Future Features",
                       icon: "sparkles",
                       detail: "Lifetime: includes every new feature")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func featureRow(_ title: String, icon: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Products

    private var productsSection: some View {
        VStack(spacing: 12) {
            if let p = storeKit.lifetimeProduct {
                purchaseButton(product: p, badge: "Best Value", highlighted: true)
            }
            if let p = storeKit.yearlyProduct {
                purchaseButton(product: p, badge: nil, highlighted: false)
            }
            if let p = storeKit.monthlyProduct {
                purchaseButton(product: p, badge: nil, highlighted: false)
            }
            if storeKit.products.isEmpty {
                Text("Products unavailable. Check your connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func purchaseButton(product: Product, badge: String?, highlighted: Bool) -> some View {
        Button {
            Task {
                isPurchasing = true
                do {
                    try await storeKit.purchase(product)
                } catch {
                    errorMessage = error.localizedDescription
                }
                isPurchasing = false
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.displayName).font(.headline)
                        Text(product.description).font(.caption).opacity(0.8)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(product.displayPrice).font(.title3.bold())
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(
                    highlighted ? Color.accentColor : Color.gray.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .foregroundStyle(highlighted ? .white : .primary)

                if let badge {
                    Text(badge)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.yellow, in: Capsule())
                        .offset(x: -10, y: -10)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
    }

    // MARK: - Restore & Footer

    private var restoreButton: some View {
        Button {
            Task {
                await storeKit.restorePurchases()
                if storeKit.isPremium { dismiss() }
            }
        } label: {
            Text("Restore Purchases")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var footerNote: some View {
        Text("Payment charged to your Apple ID. Subscription renews automatically. Cancel anytime.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 8)
    }
}
