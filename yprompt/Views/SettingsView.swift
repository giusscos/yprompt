//
//  SettingsView.swift
//  yprompt
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var storeKit: StoreKitService
    @Query private var settingsArray: [AppSettings]

    @State private var showingOnboarding = false
    @State private var showingResetConfirm = false
    @State private var showingPaywall = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        Group {
            #if os(macOS)
            macOSSettings
                .frame(minWidth: 460, minHeight: 540)
            #else
            iOSSettings
            #endif
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(isOnDemand: true)
                .environmentObject(storeKit)
                #if os(macOS)
                .frame(width: 520, height: 700)
                #endif
        }
    }

    // MARK: - macOS Settings Window

    #if os(macOS)
    private var macOSSettings: some View {
        TabView {
            ScrollView {
                VStack(spacing: 20) {
                    purchaseCard
                    syncCard
                }
                .padding(20)
            }
            .tabItem { Label("Account", systemImage: "person.circle") }

            ScrollView {
                VStack(spacing: 20) {
                    if let settings = settingsArray.first {
                        displayModeCard(settings)
                        floatingWindowCard(settings)
                        notchModeCard(settings)
                        playbackCard(settings)
                    }
                }
                .padding(20)
            }
            .tabItem { Label("Preferences", systemImage: "slider.horizontal.3") }

            ScrollView {
                VStack(spacing: 20) {
                    aboutCard
                    dangerCard
                }
                .padding(20)
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView().environmentObject(storeKit)
        }
        .confirmationDialog("Reset All Data?", isPresented: $showingResetConfirm) {
            Button("Delete Everything", role: .destructive) { resetAllData() }
        } message: {
            Text("All scripts and settings will be permanently deleted.")
        }
        .task { ensureSettingsExist() }
    }

    private var purchaseCard: some View {
        macCard {
            if storeKit.isPremium {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(storeKit.isLifetimePurchased ? "Lifetime Access" : "Subscription Active")
                            .font(.headline)
                        Text("All Pro features unlocked").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if storeKit.isSubscribed {
                    Button("Manage Subscription") { openSubscriptionManagement() }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YPrompt Free").font(.headline)
                        Text("Limited to \(AppConstants.freeScriptLimit) scripts")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Upgrade to Pro") { showingPaywall = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            Divider()
            Button("Restore Purchases") { Task { await storeKit.restorePurchases() } }
                .foregroundStyle(.secondary)
            if let error = storeKit.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var syncCard: some View {
        macCard {
            if let settings = settingsArray.first {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iCloud Sync").font(.headline)
                        if settings.cloudSyncEnabled {
                            Text(settings.lastSyncDate.map { "Last synced: \($0.shortFormatted)" }
                                 ?? "Not yet synced")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.cloudSyncEnabled },
                        set: { settings.cloudSyncEnabled = $0; try? modelContext.save() }
                    ))
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Preferences Cards (macOS)

    private func displayModeCard(_ settings: AppSettings) -> some View {
        macCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Mode").font(.headline)
                    Text("Which mode the teleprompter opens in")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { settings.displayMode },
                    set: { newMode in
                        settings.displayModeRaw = newMode.rawValue
                        try? modelContext.save()
                        FloatingTeleprompterManager.shared.notchMode = newMode == .notch
                    }
                )) {
                    Label("Floating", systemImage: "rectangle.on.rectangle").tag(DisplayMode.floatingWindow)
                    Label("Notch", systemImage: "camera").tag(DisplayMode.notch)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private func floatingWindowCard(_ settings: AppSettings) -> some View {
        macCard {
            Text("Floating Window").font(.headline)
            Divider()
            prefSliderRow("Font Size",
                value: Binding(
                    get: { settings.floatingFontSize },
                    set: { v in
                        settings.floatingFontSize = v
                        try? modelContext.save()
                        FloatingTeleprompterManager.shared.floatingFontSize = v
                    }),
                range: 12...40, step: 1,
                display: "\(Int(settings.floatingFontSize))pt")
            prefSliderRow("Width",
                value: Binding(
                    get: { settings.floatingWindowWidth },
                    set: { v in
                        settings.floatingWindowWidth = v
                        try? modelContext.save()
                        FloatingTeleprompterManager.shared.floatingWindowWidth = v
                    }),
                range: 340...1200, step: 10,
                display: "\(Int(settings.floatingWindowWidth))px")
            prefSliderRow("Height",
                value: Binding(
                    get: { settings.floatingWindowHeight },
                    set: { v in
                        settings.floatingWindowHeight = v
                        try? modelContext.save()
                        FloatingTeleprompterManager.shared.floatingWindowHeight = v
                    }),
                range: 72...340, step: 4,
                display: "\(Int(settings.floatingWindowHeight))px")
        }
    }

    private func notchModeCard(_ settings: AppSettings) -> some View {
        macCard {
            Text("Notch Mode").font(.headline)
            Divider()
            prefSliderRow("Font Size",
                value: Binding(
                    get: { settings.notchFontSize },
                    set: { v in
                        settings.notchFontSize = v
                        try? modelContext.save()
                        FloatingTeleprompterManager.shared.notchFontSize = v
                    }),
                range: 8...16, step: 1,
                display: "\(Int(settings.notchFontSize))pt")
        }
    }

    private func playbackCard(_ settings: AppSettings) -> some View {
        macCard {
            Text("Playback").font(.headline)
            Divider()
            prefSliderRow("Scroll Speed",
                value: Binding(
                    get: { settings.defaultScrollSpeed },
                    set: { v in settings.defaultScrollSpeed = v; try? modelContext.save() }),
                range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed, step: 0.1,
                display: String(format: "%.1fx", settings.defaultScrollSpeed))
        }
    }

    private func prefSliderRow(_ label: String, value: Binding<CGFloat>,
                                range: ClosedRange<CGFloat>, step: CGFloat, display: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(display).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }

    private func prefSliderRow(_ label: String, value: Binding<Double>,
                                range: ClosedRange<Double>, step: Double, display: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(display).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }

    private var aboutCard: some View {
        macCard {
            HStack {
                Text("Version").foregroundStyle(.secondary)
                Spacer()
                Text("\(appVersion) (\(buildNumber))")
            }
            Divider()
            HStack {
                Button("Send Feedback") { sendFeedback() }
                Spacer()
            }
            Divider()
            HStack {
                Button("Show App Tour") { showingOnboarding = true }
                Spacer()
            }
        }
    }

    private var dangerCard: some View {
        macCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reset All Data").font(.headline).foregroundStyle(.red)
                    Text("Permanently delete all scripts and settings")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset…", role: .destructive) { showingResetConfirm = true }
            }
        }
    }

    @ViewBuilder
    private func macCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
    }
    #endif

    // MARK: - iOS Settings

    private var iOSSettings: some View {
        Form {
            purchaseSection
            syncSection
            preferencesSection
            aboutSection
            dangerSection
        }
        .navigationTitle("Settings")
        .task { ensureSettingsExist() }
        .sheet(isPresented: $showingPaywall) {
            PaywallView().environmentObject(storeKit)
        }
        .confirmationDialog("Reset All Data?", isPresented: $showingResetConfirm) {
            Button("Delete Everything", role: .destructive) { resetAllData() }
        } message: {
            Text("All scripts and settings will be permanently deleted.")
        }
    }

    private var purchaseSection: some View {
        Section("YPrompt Pro") {
            if storeKit.isPremium {
                Label(
                    storeKit.isLifetimePurchased ? "Lifetime Access" : "Subscription Active",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
                if storeKit.isSubscribed {
                    Button("Manage Subscription") { openSubscriptionManagement() }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free Plan").font(.headline)
                    Text("Limited to \(AppConstants.freeScriptLimit) scripts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Button { showingPaywall = true } label: {
                    Label("Upgrade to Pro", systemImage: "star.fill")
                }
                .foregroundStyle(.tint)
            }
            Button("Restore Purchases") { Task { await storeKit.restorePurchases() } }
            if let error = storeKit.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var syncSection: some View {
        Section("iCloud Sync") {
            if let settings = settingsArray.first {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { settings.cloudSyncEnabled },
                    set: { settings.cloudSyncEnabled = $0; try? modelContext.save() }
                ))
                if settings.cloudSyncEnabled {
                    Text(settings.lastSyncDate.map { "Last synced: \($0.shortFormatted)" }
                         ?? "Not yet synced")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Toggle("Sync with iCloud", isOn: .constant(false)).disabled(true)
            }
        }
    }

    private var preferencesSection: some View {
        Section("Preferences") {
            if let settings = settingsArray.first {
                HStack {
                    Text("Font Size")
                    Slider(
                        value: Binding(
                            get: { settings.defaultFontSize },
                            set: { settings.defaultFontSize = $0; try? modelContext.save() }
                        ),
                        in: AppConstants.minFontSize...AppConstants.maxFontSize,
                        step: 1
                    )
                    Text("\(Int(settings.defaultFontSize))pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Scroll Speed")
                    Slider(
                        value: Binding(
                            get: { settings.defaultScrollSpeed },
                            set: { settings.defaultScrollSpeed = $0; try? modelContext.save() }
                        ),
                        in: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                        step: 0.1
                    )
                    Text(String(format: "%.1fx", settings.defaultScrollSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text("\(appVersion) (\(buildNumber))").foregroundStyle(.secondary)
            }
            Button("Send Feedback") { sendFeedback() }
            Button("Show App Tour") { showingOnboarding = true }
        }
    }

    private var dangerSection: some View {
        Section("Danger Zone") {
            Button("Reset All Data", role: .destructive) { showingResetConfirm = true }
        }
    }

    // MARK: - Actions

    private func ensureSettingsExist() {
        if settingsArray.isEmpty {
            modelContext.insert(AppSettings())
            try? modelContext.save()
        }
    }

    private func resetAllData() {
        do {
            try modelContext.fetch(FetchDescriptor<Script>()).forEach { modelContext.delete($0) }
            try modelContext.fetch(FetchDescriptor<AppSettings>()).forEach { modelContext.delete($0) }
            try modelContext.save()
        } catch { print("Reset failed: \(error)") }
    }

    private func sendFeedback() {
        #if canImport(UIKit)
        UIApplication.shared.open(URL(string: "mailto:support@yprompt.app")!)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(URL(string: "mailto:support@yprompt.app")!)
        #endif
    }

    private func openSubscriptionManagement() {
        #if canImport(UIKit)
        UIApplication.shared.open(URL(string: "itms-apps://apps.apple.com/account/subscriptions")!)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(URL(string: "https://apps.apple.com/account/subscriptions")!)
        #endif
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .modelContainer(for: [Script.self, AppSettings.self], inMemory: true)
            .environmentObject(StoreKitService())
    }
}
