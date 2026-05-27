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
                .frame(minWidth: 400, minHeight: 460)
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
            // Account / Pro tab
            ScrollView {
                VStack(spacing: 20) {
                    purchaseCard
                    syncCard
                }
                .padding(20)
            }
            .tabItem { Label("Account", systemImage: "person.circle") }

            // About tab
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
