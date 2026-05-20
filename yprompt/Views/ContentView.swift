//
//  ContentView.swift
//  yprompt
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var storeKit: StoreKitService
    @Query(sort: \Script.modifiedAt, order: .reverse) private var scripts: [Script]

    #if os(macOS)
    @State private var selectedScript: Script?
    #endif

    var body: some View {
        #if os(macOS)
        macOSContent
        #elseif os(watchOS)
        watchOSContent
        #else
        iOSContent
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
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
    #endif
}

#Preview {
    ContentView()
        .modelContainer(for: [Script.self, AppSettings.self], inMemory: true)
        .environmentObject(StoreKitService())
}
