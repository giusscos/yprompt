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
/// Lets non-view code, such as the end of a read in the floating window, open the paywall.
private struct PaywallWindowRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            FloatingTeleprompterManager.shared.presentPaywall = {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: AppConstants.paywallWindowID)
            }
        }
    }
}

private struct MenuBarScriptsLoader: View {
    @Query(sort: \Script.modifiedAt, order: .reverse) private var scripts: [Script]
    @Environment(StoreKitService.self) private var storeKit
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarView()
            .onAppear {
                let manager = FloatingTeleprompterManager.shared
                manager.registeredScripts = scripts
                // The menu bar can be used without the main window ever opening.
                manager.storeKit = storeKit
                manager.presentPaywall = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: AppConstants.paywallWindowID)
                }
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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ReadingFont.registerBundledFonts()
    }

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
                .modifier(PaywallWindowRegistration())
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await storeKit.refreshEntitlements() } }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 750)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(storeKit)
                .modelContainer(sharedModelContainer)
        }

        Window("yPrompt Pro", id: AppConstants.paywallWindowID) {
            PaywallView(context: FloatingTeleprompterManager.shared.paywallContext)
                .environment(storeKit)
                .frame(minWidth: 460, minHeight: 680)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("yPrompt", systemImage: "scroll") {
            MenuBarScriptsLoader()
                .environment(storeKit)
                .modelContainer(sharedModelContainer)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}
