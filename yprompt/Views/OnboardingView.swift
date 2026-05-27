//
//  OnboardingView.swift
//  yprompt
//

import SwiftUI

struct OnboardingView: View {
    var isOnDemand: Bool = false

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storeKit: StoreKitService

    @State private var currentStep = 0
    @State private var showPaywall = false

    private let totalSteps = 5

    var body: some View {
        ZStack(alignment: .bottom) {
            #if os(iOS)
            TabView(selection: $currentStep) {
                welcomePage.frame(maxWidth: .infinity, maxHeight: .infinity).tag(0)
                scriptsPage.frame(maxWidth: .infinity, maxHeight: .infinity).tag(1)
                modesPage.frame(maxWidth: .infinity, maxHeight: .infinity).tag(2)
                platformPage.frame(maxWidth: .infinity, maxHeight: .infinity).tag(3)
                proPage.frame(maxWidth: .infinity, maxHeight: .infinity).tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .padding(.bottom, 130)
            #else
            ZStack {
                switch currentStep {
                case 0: welcomePage
                case 1: scriptsPage
                case 2: modesPage
                case 3: platformPage
                default: proPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(currentStep)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal:   .move(edge: .leading).combined(with: .opacity)
            ))
            .padding(.bottom, 130)
            #endif

            VStack(spacing: 0) {
                Divider()
                bottomNavigation
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
            }
            .background(.regularMaterial)
        }
        .overlay(alignment: .topTrailing) {
            if isOnDemand {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(16)
            }
        }
        .interactiveDismissDisabled(!isOnDemand)
        .onChange(of: storeKit.isPremium) { _, isPremium in
            guard isPremium else { return }
            if isOnDemand { dismiss() } else { hasSeenOnboarding = true }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(storeKit)
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "scroll.fill")
                    .font(.system(size: 80))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)
                VStack(spacing: 10) {
                    Text("Welcome to YPrompt")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("The professional teleprompter for creators, speakers, and broadcasters on every Apple platform.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var scriptsPage: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 80))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                VStack(spacing: 10) {
                    Text("Write & Import")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Type from scratch, paste any text, or start from a template. All your scripts in one place.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var modesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Read on Your Terms")
                    .font(.largeTitle.bold())
                featureRow("scroll",        .blue,   "Auto",   "Smooth continuous scroll at your chosen pace.")
                featureRow("hand.tap.fill", .orange, "Tap",    "Advance each line manually with a tap.")
                featureRow("mic.fill",      .purple, "Voice",  "Hands-free scrolling driven by your voice.", badge: "Pro")
                featureRow("video.fill",    .red,    "Camera", "Record video while your script scrolls.", badge: "Pro")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
        }
    }

    #if os(macOS)
    private var platformPage: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 80))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.indigo)
                VStack(spacing: 10) {
                    Text("Float Near Your Camera")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("A floating window hovers just below your webcam so you look straight into the lens while delivering every word.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }
    #else
    private var platformPage: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 80))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.cyan)
                VStack(spacing: 10) {
                    Text("Record as You Read")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Enable Camera mode to capture professional-looking video while your script scrolls perfectly in sync.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }
    #endif

    private var proPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 56))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.yellow)
                    Text("YPrompt Pro")
                        .font(.largeTitle.bold())
                    Text("Unlock everything.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

                featureRow("doc.fill",          .blue,   "Unlimited Scripts",    "No cap on how many you can create.")
                featureRow("mic.fill",          .purple, "Voice Scroll",         "Hands-free scrolling driven by your voice.")
                featureRow("video.fill",        .red,    "Camera Recording",     "Record while the teleprompter rolls.")
                featureRow("paintpalette.fill", .pink,   "Custom Fonts & Colors","Full visual control over your scripts.")
                featureRow("icloud.fill",       .cyan,   "iCloud Sync",          "Access your scripts on all your devices.")
                featureRow("sparkles",          .orange, "All Future Features",  "Every update included with Lifetime access.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
        }
    }

    private func featureRow(_ icon: String, _ color: Color, _ title: String, _ desc: String, badge: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(desc).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bottom Navigation

    private var bottomNavigation: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: i == currentStep ? 20 : 6, height: 6)
                        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: currentStep)
                }
            }

            if currentStep < totalSteps - 1 {
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { currentStep += 1 }
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(spacing: 10) {
                    Button {
                        if isOnDemand { dismiss() } else { hasSeenOnboarding = true }
                    } label: {
                        Text(isOnDemand ? "Done" : "Get Started").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button { showPaywall = true } label: {
                        Text("Unlock Pro")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}
