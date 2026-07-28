//
//  OnboardingView.swift
//  yprompt
//

import SwiftUI
import StoreKit

struct OnboardingView: View {
    var isOnDemand: Bool = false

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase
    @Environment(StoreKitService.self) private var storeKit

    @State private var teleprompterOffset: CGFloat = 80

    private enum Step: Hashable {
        case scripts, modes, platform, pro
    }

    var body: some View {
        NavigationStack {
            welcomePage
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .scripts:  scriptsPage
                    case .modes:    modesPage
                    case .platform: platformPage
                    case .pro:      proPage
                    }
                }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .presentationBackground(.ultraThinMaterial)
        .interactiveDismissDisabled(!isOnDemand)
        .onChange(of: storeKit.isPremium) { _, isPremium in
            guard isPremium else { return }
            if isOnDemand { dismiss() } else { hasSeenOnboarding = true }
        }
    }

    // MARK: - Shared bottom bar

    private func navCTABar(next: Step) -> some View {
        NavigationLink(value: next) {
            Text("Continue")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(Color.accentColor)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom)
        .background { blurFade }
    }

    private var proBottomBar: some View {
        VStack(spacing: 12) {
            Button {
                if isOnDemand { dismiss() } else { hasSeenOnboarding = true }
            } label: {
                Text("Get Started for Free")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.accentColor)

            HStack(spacing: 0) {
                Link("Privacy Policy", destination: URL(string: "https://yprompt.app/privacy")!)
                Text(" & ").foregroundStyle(.tertiary)
                Link("Terms of Use", destination: URL(string: "https://yprompt.app/terms")!)
                Spacer()
                Button("Restore Purchases") {
                    Task { await storeKit.restorePurchases() }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background { blurFade }
    }

    private var blurFade: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .padding(.top, -56)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.45)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()
    }

    // MARK: - Page 1: Welcome with live teleprompter preview

    private var welcomePage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                teleprompterPreviewCard
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .task {
                        teleprompterOffset = 180
                        try? await Task.sleep(for: .milliseconds(600))
                        withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                            teleprompterOffset = -300
                        }
                    }
                VStack(spacing: 10) {
                    Text("Read with Confidence.\nEvery Time.")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("The professional teleprompter for creators, speakers, and broadcasters on every Apple platform.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navCTABar(next: .scripts) }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
#if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .fontWeight(.semibold)
                }
            }
        }
#endif
    }

    private var teleprompterPreviewCard: some View {
        ZStack {
            Color.black
            Text("Good morning everyone, and welcome to today's keynote. I'm truly honored to be here with all of you. Over the past year, our team has been building something we believe will change the way you communicate. Whether you're a podcaster, a speaker, or a content creator — today is the day everything changes.\n\nLet me start by sharing the vision behind this product...")
                .font(.body)
                .foregroundStyle(.white)
                .lineSpacing(6)
                .padding(.horizontal, 18)
                .offset(y: teleprompterOffset)
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.78),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.caption2)
                        Text("1.0×").font(.caption2.bold())
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .padding(10)
                }
                Spacer()
            }
        }
    }

    // MARK: - Page 2: Scripts list preview

    private var scriptsPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("All Your Scripts,")
                        .font(.largeTitle.bold())
                    Text("One Place.")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.blue)
                    Text("Write from scratch, paste any text, or use a template. Organised with tags and search.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .padding(.top, 36)
                .padding(.horizontal, 24)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        dummyTagPill("All", selected: true)
                        dummyTagPill("Work", selected: false)
                        dummyTagPill("Podcast", selected: false)
                        dummyTagPill("Personal", selected: false)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 14)
                .padding(.bottom, 6)

                VStack(spacing: 0) {
                    let dummyScripts: [(title: String, preview: String, date: String, tag: String?)] = [
                        ("Product Launch Keynote", "Good morning everyone, and welcome to today's...", "Today", "Work"),
                        ("Podcast Intro — Ep. 42", "Hey listeners! Welcome back to The Weekly Drop...", "Yesterday", "Podcast"),
                        ("Wedding Toast for Sarah", "To Sarah and Michael — two people who found...", "Jun 1", "Personal"),
                        ("Morning News Briefing", "Good morning. Here are today's top headlines...", "May 30", "Work"),
                    ]
                    ForEach(Array(dummyScripts.enumerated()), id: \.offset) { i, script in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(script.title)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)
                                    if let tag = script.tag {
                                        Text(tag)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.12))
                                            .foregroundStyle(.blue)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(script.preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(script.date)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        if i < dummyScripts.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .glassEffect(in: .rect(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navCTABar(next: .modes) }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
    }

    private func dummyTagPill(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.15))
            .foregroundStyle(selected ? .white : .primary)
            .clipShape(Capsule())
    }

    // MARK: - Page 3: Modes with selector preview

    private var modesPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read on")
                        .font(.largeTitle.bold())
                    Text("Your Terms.")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.blue)
                }
                modeSelectorPreview
                VStack(alignment: .leading, spacing: 20) {
                    featureRow("scroll",        .blue,   "Auto",   "Smooth continuous scroll at your chosen pace.")
                    featureRow("hand.tap.fill", .orange, "Tap",    "Advance each line manually with a tap.")
                    featureRow("mic.fill",      .purple, "Voice",  "Hands-free scrolling driven by your voice.", badge: "Pro")
                    featureRow("video.fill",    .red,    "Camera", "Record video while your script scrolls.", badge: "Pro")
                    featureRow("timer",         .teal,   "Timed",  "Auto-pace to hit your target duration.", badge: "Pro")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navCTABar(next: .platform) }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
    }

    private var modeSelectorPreview: some View {
        let modes: [(icon: String, label: String, isActive: Bool)] = [
            ("scroll",        "Auto",   true),
            ("hand.tap.fill", "Tap",    false),
            ("mic",           "Voice",  false),
            ("video",         "Camera", false),
            ("timer",         "Timed",  false),
        ]
        return HStack(spacing: 2) {
            ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
                VStack(spacing: 4) {
                    Image(systemName: mode.icon).font(.caption)
                    Text(mode.label).font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(mode.isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                .foregroundStyle(mode.isActive ? Color.accentColor : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(4)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    // MARK: - Page 4: Platform-specific preview

#if os(macOS)
    private var platformPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                floatingWindowMockup
                    .frame(height: 130)
                VStack(spacing: 10) {
                    Text("Float Near\nYour Camera")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("A floating window hovers just below your webcam so you look straight into the lens while delivering every word.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navCTABar(next: .pro) }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
    }

    private var floatingWindowMockup: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 8, height: 8)
                    Spacer()
                    Text("Floating Teleprompter")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.primary.opacity(0.04))
                Divider()
                Text("Good morning everyone, and welcome to today's keynote. I'm honored to share what we've built...")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineSpacing(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(width: 280)
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            .offset(y: -10)
        }
    }
#else
    private var platformPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                cameraMockup
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                VStack(spacing: 10) {
                    Text("Record\nAs You Read")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Camera mode captures professional-quality video while your script scrolls perfectly in sync — no teleprompter visible to your audience.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 56)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navCTABar(next: .pro) }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
    }

    private var cameraMockup: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: 0.58, saturation: 0.35, brightness: 0.22),
                    Color(hue: 0.55, saturation: 0.45, brightness: 0.16)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 46, height: 46)
                    .offset(y: 4)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray)
                    .frame(width: 72, height: 62)
            }
            .offset(y: -10)
            VStack {
                Spacer()
                Text("Good morning everyone, and welcome...")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.5))
            }
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("REC").font(.caption2.bold()).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .padding(10)
                }
                Spacer()
            }
        }
    }
#endif

    // MARK: - Page 5: Pro with inline pricing

    private var proPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "crown.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.yellow, .yellow.opacity(0.5))
                    Text("yPrompt Pro")
                        .font(.largeTitle.bold())
                    Text("Unlock everything. No limits.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

                if storeKit.isLoading {
                    ProgressView("Loading products…").padding()
                } else {
                    inlinePricingCards
                }

                VStack(alignment: .leading, spacing: 16) {
                    featureRow("doc.fill",          .blue,   "Unlimited Scripts",     "No cap on how many you can create.")
                    featureRow("mic.fill",          .purple, "Voice Scroll",          "Hands-free scrolling driven by your voice.")
                    featureRow("video.fill",        .red,    "Camera Recording",   "Record while the teleprompter rolls.")
                    featureRow("paintpalette.fill", .pink,   "Custom Colors",      "Choose your own text and background colors.")
                    featureRow("textformat.size",   .teal,   "Font Size Control",  "Adjust the reading size to your comfort.")
                    featureRow("macwindow",         .indigo, "Floating Window",    "Pin the teleprompter above any app on Mac.")
                    featureRow("icloud.fill",       .cyan,   "iCloud Sync",        "Access your scripts on all your devices.")
                    featureRow("sparkles",          .orange, "All Future Features","Every update included with Lifetime access.")
                }
                .padding(16)
                .glassEffect(in: .rect(cornerRadius: 16))
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { proBottomBar }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
#if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .fontWeight(.semibold)
                }
            }
        }
#endif
    }

    private var inlinePricingCards: some View {
        VStack(spacing: 10) {
            if let p = storeKit.lifetimeProduct {
                pricingCard(name: p.displayName, price: p.displayPrice, desc: p.description, badge: "Best Value", highlighted: true) {
                    Task { try? await storeKit.purchase(p) { try await purchase($0) } }
                }
            }
            if let p = storeKit.yearlyProduct {
                pricingCard(name: p.displayName, price: p.displayPrice, desc: p.description, badge: nil, highlighted: false) {
                    Task { try? await storeKit.purchase(p) { try await purchase($0) } }
                }
            }
            if let p = storeKit.weeklyProduct {
                pricingCard(name: p.displayName, price: p.displayPrice, desc: p.description, badge: nil, highlighted: false) {
                    Task { try? await storeKit.purchase(p) { try await purchase($0) } }
                }
            }
            if storeKit.products.isEmpty {
                Text("Products unavailable — check your connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)
            }
        }
    }

    private func pricingCard(name: String, price: String, desc: String, badge: String?, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline)
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(price).font(.title3.bold())
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .glassEffect(highlighted ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .rect(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.caption2.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.yellow, in: Capsule())
                        .offset(x: -10, y: -10)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared helpers

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
}
