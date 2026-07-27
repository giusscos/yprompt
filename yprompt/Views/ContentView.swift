//
//  ContentView.swift
//  yprompt
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(StoreKitService.self) private var storeKit
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Script.modifiedAt, order: .reverse) private var scripts: [Script]
    @Query private var settingsArray: [AppSettings]
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    #if os(macOS)
    @State private var selectedScript: Script?
    #endif

    var body: some View {
        Group {
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
        .task { seedDemoScriptsIfNeeded() }
    }

    // MARK: - Demo Seeding

    private func seedDemoScriptsIfNeeded() {
        guard scripts.isEmpty else { return }

        struct DemoScript {
            let title: String
            let content: String
            let tags: [String]
            let isFavorite: Bool
            let daysAgo: Int
        }

        let demos: [DemoScript] = [
            DemoScript(
                title: "Product Launch Keynote",
                content: """
                    Good morning, everyone.

                    Thank you for being here today. What we're about to share has been months in the making — and I couldn't be more excited to unveil it.

                    Every once in a while, a product comes along that changes the way you think about something you do every day. We believe today is one of those moments.

                    Our team started with a single question: what does the future of this look like? Not an incremental update — but something genuinely new.

                    The answer is what we're announcing today.

                    We built it for the people who care about their work. For the professionals who need reliability. For the creators who want tools that keep pace with their ideas.

                    We've tested it. We've refined it. We've rebuilt it from scratch more than once.

                    And now — it's ready.

                    So without any further delay, let me show you exactly what we've been working on.

                    I think you're going to love it.
                    """,
                tags: ["Work"],
                isFavorite: true,
                daysAgo: 0
            ),
            DemoScript(
                title: "Podcast Intro — Ep. 42",
                content: """
                    Hey everyone — welcome back to The Daily Drop.

                    I'm your host, and you're listening to episode forty-two. If this is your first time here, welcome. We cover the ideas, stories, and strategies reshaping the way we work and live.

                    Today's episode is one I've been looking forward to for a long time.

                    We're exploring something that touches every person who creates content for a living — whether you're a writer, a designer, a developer, or a podcaster like me.

                    My guest today has spent the last decade working at the intersection of creativity and technology. Their ideas have influenced more people than they probably know.

                    This conversation goes places I didn't expect. I think you'll walk away with at least one idea you'll want to act on immediately.

                    Before we dive in: if you enjoy the show, please leave a review. It makes a real difference and helps new listeners find us.

                    Alright — let's get into it.
                    """,
                tags: ["Podcast"],
                isFavorite: false,
                daysAgo: 1
            ),
            DemoScript(
                title: "Wedding Toast for Sarah",
                content: """
                    To Sarah and Michael.

                    I've been rehearsing this speech for three weeks. And yet, standing here right now, looking at the two of you — I've forgotten every single word I prepared.

                    So I'm going to say what's in my heart instead.

                    Sarah, I've known you since we were twelve years old. I was there the first time you laughed so hard you cried. I was there when things were hard. And over the years, I've watched you become one of the most remarkable people I've ever known.

                    And Michael — I want you to know something. The first time Sarah mentioned your name on the phone, there was something different in her voice. Something I hadn't heard before. That told me everything I needed to know.

                    What you two have isn't just a relationship. It's a home. A safe place. A life built with care and intention.

                    I am so glad you found each other.

                    So please raise your glasses.

                    To Sarah and Michael — may every year you share be better than the last.
                    """,
                tags: ["Personal"],
                isFavorite: false,
                daysAgo: 2
            )
        ]

        for demo in demos {
            let script = Script(title: demo.title, content: demo.content)
            script.tags = demo.tags
            script.isFavorite = demo.isFavorite
            let date = Date().addingTimeInterval(TimeInterval(-demo.daysAgo * 86400))
            script.createdAt = date
            script.modifiedAt = date
            modelContext.insert(script)
        }
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
        mgr.notchScrollVertical = settings.notchScrollVertical
        mgr.floatingWindowWidth = settings.floatingWindowWidth
        mgr.floatingWindowHeight = settings.floatingWindowHeight
        mgr.notchMode = settings.displayMode == .notch
    }

    private var emptyDetail: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.quaternary)
            VStack(spacing: 8) {
                Text("No Script Selected")
                    .font(.title2.bold())
                Text("Select a script from the sidebar, or press ⌘N to create a new one.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
