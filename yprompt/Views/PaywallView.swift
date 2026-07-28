//
//  PaywallView.swift
//  yprompt
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase
    @Environment(StoreKitService.self) private var storeKit

    @State private var isPurchasing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    featuresSection
                    if storeKit.isLoading {
                        ProgressView("Loading products…").padding()
                    } else {
                        productsSection
                    }
                    legalSection
                }
                .padding()
            }
            .navigationTitle("yPrompt Pro")
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
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.yellow)
            VStack(spacing: 6) {
                Text("Unlock yPrompt Pro")
                    .font(.title2.bold())
                Text("Professional tools for every presenter.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow("mic.fill",          .purple, "Voice Scroll",          "Hands-free scrolling driven by your voice")
            featureRow("video.fill",        .red,    "Camera Mode",           "Record while the teleprompter rolls")
            featureRow("doc.fill",          .blue,   "Unlimited Scripts",  "No cap on how many you can create")
            featureRow("paintpalette.fill", .pink,   "Custom Colors",       "Choose your own text and background colors")
            featureRow("textformat.size",   .teal,   "Font Size Control",   "Adjust the reading size to your comfort")
            featureRow("macwindow",         .indigo, "Floating Window",     "Pin the teleprompter above any app on Mac")
            featureRow("icloud.fill",       .cyan,   "iCloud Sync",         "Access your scripts on all your devices")
            featureRow("sparkles",          .orange, "All Future Features", "Lifetime includes every new feature")
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 16))
    }

    private func featureRow(_ icon: String, _ color: Color, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(desc).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Products

    private var productsSection: some View {
        VStack(spacing: 12) {
            if let p = storeKit.lifetimeProduct {
                productCard(p, badge: "Best Value", highlighted: true)
            }
            if let p = storeKit.yearlyProduct {
                productCard(p, badge: nil, highlighted: false)
            }
            if let p = storeKit.weeklyProduct {
                productCard(p, badge: nil, highlighted: false)
            }
            if storeKit.products.isEmpty {
                Text("Products unavailable. Check your connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func productCard(_ product: Product, badge: String?, highlighted: Bool) -> some View {
        Button {
            Task {
                isPurchasing = true
                do {
                    try await storeKit.purchase(product) { try await purchase($0) }
                } catch {
                    errorMessage = error.localizedDescription
                }
                isPurchasing = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName).font(.headline)
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(product.displayPrice).font(.title3.bold())
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .glassEffect(highlighted ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .rect(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
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
        .disabled(isPurchasing)
    }

    // MARK: - Legal

    private var legalSection: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    await storeKit.restorePurchases()
                    if storeKit.isPremium { dismiss() }
                }
            } label: {
                Text("Restore Purchases")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)

            Text("Payment is charged to your Apple ID. Subscriptions renew automatically until cancelled.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Privacy Policy", destination: AppConstants.privacyPolicyURL)
                Text("·").foregroundStyle(.tertiary)
                Link("Terms of Use", destination: AppConstants.termsOfUseURL)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}
