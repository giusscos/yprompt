//
//  ypromptApp.swift
//  yprompt
//

import SwiftUI
import SwiftData

@main
struct ypromptApp: App {
    @StateObject private var storeKit = StoreKitService()

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
                .environmentObject(storeKit)
        }
        .modelContainer(sharedModelContainer)

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(storeKit)
                .modelContainer(sharedModelContainer)
        }

        MenuBarExtra("YPrompt", systemImage: "scroll") {
            MenuBarView()
                .modelContainer(sharedModelContainer)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}
