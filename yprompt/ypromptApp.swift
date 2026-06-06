//
//  ypromptApp.swift
//  yprompt
//

import SwiftUI
import SwiftData

// Thin wrapper so @Query works inside MenuBarExtra (no custom init needed).
// Keeps FloatingTeleprompterManager.registeredScripts in sync independently
// of whether the main window is open.
#if os(macOS)
private struct MenuBarScriptsLoader: View {
    @Query(sort: \Script.modifiedAt, order: .reverse) private var scripts: [Script]

    var body: some View {
        MenuBarView()
            .onAppear {
                FloatingTeleprompterManager.shared.registeredScripts = scripts
            }
            .onChange(of: scripts) { _, newScripts in
                FloatingTeleprompterManager.shared.registeredScripts = newScripts
            }
    }
}
#endif

@main
struct ypromptApp: App {
    @State private var storeKit = StoreKitService()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Script.self, AppSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(storeKit)
                #if os(macOS)
                .onAppear {
                    FloatingTeleprompterManager.shared.storeKit = storeKit
                    RemoteControlService.shared.startAdvertising()
                }
                #elseif os(iOS)
                .onAppear {
                    WatchSessionRelay.shared.activate()
                }
                #endif
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
        .defaultSize(width: 1000, height: 750)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(storeKit)
                .modelContainer(sharedModelContainer)
        }

        MenuBarExtra("YPrompt", systemImage: "scroll") {
            MenuBarScriptsLoader()
                .modelContainer(sharedModelContainer)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}
