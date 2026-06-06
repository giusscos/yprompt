//
//  ContentView.swift
//  yprompt
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(StoreKitService.self) private var storeKit
    @Query(sort: \Script.modifiedAt, order: .reverse) private var scripts: [Script]
    @Query private var settingsArray: [AppSettings]
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    #if os(macOS)
    @State private var selectedScript: Script?
    #endif

    var body: some View {
        #if os(macOS)
        macOSContent
            .sheet(isPresented: Binding(get: { !hasSeenOnboarding }, set: { _ in })) {
                OnboardingView()
                    .environment(storeKit)
                    .frame(width: 520, height: 700)
            }
        #elseif os(watchOS)
        watchOSContent
        #else
        iOSContent
            .fullScreenCover(isPresented: Binding(get: { !hasSeenOnboarding }, set: { _ in })) {
                OnboardingView()
                    .environment(storeKit)
            }
        #endif
    }

    // MARK: - macOS

    #if os(macOS)
    private var macOSContent: some View {
        NavigationSplitView {
            ScriptsListView(selectedScript: $selectedScript)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270)
        } detail: {
            if let script = selectedScript {
                EditorView(script: script)
            } else {
                emptyDetail
            }
        }
        .onAppear {
            FloatingTeleprompterManager.shared.registeredScripts = scripts
            applySettingsToManager()
        }
        .onChange(of: scripts) { _, newScripts in
            FloatingTeleprompterManager.shared.registeredScripts = newScripts
        }
    }

    private func applySettingsToManager() {
        guard let settings = settingsArray.first else { return }
        let mgr = FloatingTeleprompterManager.shared
        mgr.floatingFontSize = settings.floatingFontSize
        mgr.notchFontSize = settings.notchFontSize
        mgr.floatingWindowWidth = settings.floatingWindowWidth
        mgr.floatingWindowHeight = settings.floatingWindowHeight
        mgr.notchMode = settings.displayMode == .notch
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No Script Selected")
                .font(.title2.bold())
            Text("Choose a script from the sidebar or create a new one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    #endif

    // MARK: - watchOS

    #if os(watchOS)
    private var watchOSContent: some View {
        NavigationStack {
            List(scripts) { script in
                NavigationLink(value: script) {
                    Text(script.title).font(.headline)
                }
            }
            .navigationTitle("YPrompt")
            .navigationDestination(for: Script.self) { script in
                TeleprompterView(script: script)
            }
        }
    }
    #endif

    // MARK: - iOS / iPadOS

    #if !os(macOS) && !os(watchOS)
    private var iOSContent: some View {
        TabView {
            NavigationStack {
                ScriptsListView()
            }
            .tabItem { Label("Scripts", systemImage: "doc.text") }

            NavigationStack {
                RemoteControlView()
            }
            .tabItem { Label("Remote", systemImage: "appletvremote.gen4.fill") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear {
            WatchSessionRelay.shared.localScripts = scripts
        }
        .onChange(of: scripts) { _, newScripts in
            WatchSessionRelay.shared.localScripts = newScripts
        }
    }
    #endif
}

#Preview {
    ContentView()
        .modelContainer(for: [Script.self, AppSettings.self], inMemory: true)
        .environment(StoreKitService())
}
