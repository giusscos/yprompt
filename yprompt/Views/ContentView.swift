//
//  ContentView.swift
//  yprompt
//

import SwiftUI
import TipKit
import SwiftData

struct ContentView: View {
    @Environment(StoreKitService.self) private var storeKit
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Script.modifiedAt, order: .reverse) private var scripts: [Script]
    @Query private var settingsArray: [AppSettings]
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage(WhatsNew.seenKey) private var whatsNewSeen = ""

    #if os(macOS)
    @State private var selectedScript: Script?
    @State private var sidebarMode: SidebarMode = .scripts
    /// The recording open in the editor, with the piece to select when it opens.
    @State private var openRecording: RecordingSelection?
    private let manager = FloatingTeleprompterManager.shared

    private enum SidebarMode: Hashable {
        case scripts, recordings
    }
    #endif
    @State private var selectedTab = 0
    /// The first-run tour waits for the Pro check, so it doesn't appear and then vanish for Pro users.
    @State private var onboardingReady = false

    var body: some View {
        Group {
            #if os(macOS)
            macOSContent
                .sheet(isPresented: Binding(get: { onboardingReady && !hasSeenOnboarding }, set: { _ in })) {
                    OnboardingView()
                        .environment(storeKit)
                        .frame(width: 520, height: 700)
                }
                .sheet(isPresented: isWhatsNewPresented) {
                    WhatsNewView()
                        .environment(storeKit)
                        .frame(width: 480, height: 560)
                }
            #elseif os(watchOS)
            watchOSContent
            #else
            iOSContent
                .fullScreenCover(isPresented: Binding(get: { onboardingReady && !hasSeenOnboarding }, set: { _ in })) {
                    OnboardingView()
                        .environment(storeKit)
                }
                .sheet(isPresented: isWhatsNewPresented) {
                    WhatsNewView()
                        .environment(storeKit)
                }
            #endif
        }
        .task {
            // A new install has nothing to catch up on.
            if !hasSeenOnboarding { whatsNewSeen = WhatsNew.release }
            seedStartingScripts()
            ScriptIndex.rebuild()
        }
        .onChange(of: scripts) { _, scripts in removeSyncedWelcomeCopies(in: scripts) }
        .task { await prepareOnboarding() }
        .onOpenURL { url in
            #if os(macOS)
            if url.host() == "write" { sidebarMode = .scripts }
            #else
            if url.host() == "write" { selectedTab = 0 }
            #endif
            AppRouter.shared.handle(url)
        }
        .onChange(of: storeKit.isPremium, initial: true) { _, premium in TipState.isPro = premium }
        .onChange(of: scripts.count, initial: true) { _, _ in donateFirstOwnScriptIfNeeded() }
    }

    private var isWhatsNewPresented: Binding<Bool> {
        Binding(
            get: {
                #if DEBUG
                // For App Store screenshots.
                if ProcessInfo.processInfo.arguments.contains("-ypShotWhatsNew") { return whatsNewSeen != "shot" }
                #endif
                return hasSeenOnboarding && whatsNewSeen != WhatsNew.release
            },
            set: {
                guard !$0 else { return }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ypShotWhatsNew") { whatsNewSeen = "shot"; return }
                #endif
                whatsNewSeen = WhatsNew.release
            }
        )
    }

    // MARK: - Tips

    /// The New Script tip goes away once there's a script besides the sample one.
    private func donateFirstOwnScriptIfNeeded() {
        let key = "yprompt.tips.ownScriptDonated"
        guard !UserDefaults.standard.bool(forKey: key),
              scripts.contains(where: { $0.id != AppConstants.welcomeScriptID }) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { await TipState.scriptCreated.donate() }
    }

    // MARK: - Onboarding

    /// Waits (up to three seconds) for the first Pro check. Someone who already has Pro skips
    /// the tour, which ends on a sales page, instead of seeing it open and close by itself.
    private func prepareOnboarding() async {
        guard !hasSeenOnboarding else { onboardingReady = true; return }
        for _ in 0..<30 where !storeKit.hasCheckedEntitlements {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if storeKit.isPremium { hasSeenOnboarding = true }
        onboardingReady = true
    }

    // MARK: - Welcome Script

    private func seedStartingScripts() {
        #if DEBUG
        // Sample scripts for App Store screenshots, only in the in-memory library `-ypDemoStore`
        // opens. A debug build on a real device behaves like the App Store app, so it never
        // adds them to someone's own library (and iCloud).
        if ProcessInfo.processInfo.arguments.contains("-ypDemoStore") {
            seedDemoScriptsIfNeeded()
            return
        }
        #endif
        seedWelcomeScriptIfNeeded()
    }

    /// New installs start with a short script that shows how reading feels, ready to play.
    private func seedWelcomeScriptIfNeeded() {
        let seededKey = "hasSeededWelcomeScript"
        guard !hasSeenOnboarding, !UserDefaults.standard.bool(forKey: seededKey) else { return }
        // Ask the store itself: the list on screen can still be loading at launch.
        guard AppDataStore.script(id: AppConstants.welcomeScriptID) == nil,
              AppDataStore.allScripts().isEmpty else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        let script = Script(
            title: String(localized: "Welcome to yPrompt"),
            content: String(localized: "Welcome to yPrompt. Press play and read this out loud at your own pace. Every word lights up as you go, just like song lyrics.\n\nKeep your eyes near the camera and your voice will sound natural. When you are ready, add your own script and speak with confidence.")
        )
        script.id = AppConstants.welcomeScriptID
        modelContext.insert(script)
        try? modelContext.save()
    }

    /// Each device seeds the script before iCloud has delivered anything; keep just one.
    private func removeSyncedWelcomeCopies(in scripts: [Script]) {
        let copies = scripts.filter { $0.id == AppConstants.welcomeScriptID }
        guard copies.count > 1 else { return }
        copies.dropFirst().forEach(modelContext.delete)
        try? modelContext.save()
    }

    // MARK: - Demo Seeding

    #if DEBUG

    private func seedDemoScriptsIfNeeded() {
        // Titles already in the library, read from the store rather than the list on screen.
        let existingTitles = Set(AppDataStore.allScripts().map(\.title))

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

        for demo in demos where !existingTitles.contains(demo.title) {
            let script = Script(title: demo.title, content: demo.content)
            script.tags = demo.tags
            script.isFavorite = demo.isFavorite
            let date = Date().addingTimeInterval(TimeInterval(-demo.daysAgo * 86400))
            script.createdAt = date
            script.modifiedAt = date
            modelContext.insert(script)
        }
    }
    #endif

    // MARK: - macOS

    #if os(macOS)
    private var macOSContent: some View {
        NavigationSplitView {
            Group {
                switch sidebarMode {
                case .scripts:
                    ScriptsListView(selectedScript: $selectedScript)
                case .recordings:
                    RecordingsListView(selection: recordingSelection)
                }
            }
            // An empty list shows a message that doesn't fill the column; without this the
            // Scripts/Recordings switch would follow it to the middle.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top) {
                Picker("Show", selection: $sidebarMode) {
                    Text("Scripts").tag(SidebarMode.scripts)
                    Text("Recordings").tag(SidebarMode.recordings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 270)
        } detail: {
            switch sidebarMode {
            case .scripts:
                if let script = selectedScript {
                    EditorView(script: script)
                } else {
                    emptyDetail
                }
            case .recordings:
                if let openRecording {
                    recordingEditor(openRecording)
                } else {
                    ContentUnavailableView("No Recording Selected", systemImage: "film.stack",
                                           description: Text("Pick a recording in the sidebar to watch and edit it."))
                }
            }
        }
        // Below this the editor's strip, options and buttons stop being readable.
        .frame(minWidth: 1080, minHeight: 640)
        .onAppear {
            FloatingTeleprompterManager.shared.registeredScripts = scripts
            applySettingsToManager()
            showRequestedRecording()
        }
        .onChange(of: manager.requestedRecording) { _, _ in showRequestedRecording() }
        .onChange(of: AppRouter.shared.pending, initial: true) { _, _ in showRoutedScript() }
        .onChange(of: scripts) { _, newScripts in
            FloatingTeleprompterManager.shared.registeredScripts = newScripts
        }
    }

    private var recordingSelection: Binding<UUID?> {
        Binding(get: { openRecording?.recordingID },
                set: { id in openRecording = id.map { RecordingSelection(recordingID: $0) } })
    }

    /// A Shortcut, Siri or Spotlight asked for a script.
    private func showRoutedScript() {
        guard let destination = AppRouter.shared.take() else { return }
        switch destination {
        case .editor(let id):
            sidebarMode = .scripts
            selectedScript = scripts.first { $0.id == id } ?? AppDataStore.script(id: id)
        case .teleprompter(let id):
            if let script = AppDataStore.script(id: id) {
                manager.show(script: script, storeKit: storeKit)
            }
        }
    }

    /// A take that just finished: show it in the editor.
    private func showRequestedRecording() {
        guard let request = manager.requestedRecording else { return }
        manager.requestedRecording = nil
        sidebarMode = .recordings
        openRecording = request
    }

    private func recordingEditor(_ selection: RecordingSelection) -> some View {
        let recording = RecordingLibrary.shared.recording(selection.recordingID)
        let script = scripts.first { $0.id == recording?.scriptID }
        return RecordingEditorView(
            selection: selection,
            script: script?.scriptWords,
            onRecordMore: script.map { script in
                { pickup in
                    openRecording = nil
                    manager.startPickup(pickup, script: script)
                }
            },
            onClose: { openRecording = nil }
        )
        .environment(storeKit)
        // A new editor for each recording, and again when a take was added to the open one.
        .id("\(selection.recordingID)-\(selection.pieceID?.uuidString ?? "")")
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
            .navigationTitle("yPrompt")
            .navigationDestination(for: Script.self) { script in
                TeleprompterView(script: script)
            }
        }
    }
    #endif

    // MARK: - iOS / iPadOS

    #if !os(macOS) && !os(watchOS)
    private var iOSContent: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScriptsListView()
            }
            .tabItem { Label("Scripts", systemImage: "doc.text") }
            .tag(0)

            #if os(iOS)
            NavigationStack {
                RecordingsListView()
            }
            .tabItem { Label("Recordings", systemImage: "film.stack") }
            .tag(1)
            #endif

            NavigationStack {
                RemoteControlView()
            }
            .tabItem { Label("Remote", systemImage: "appletvremote.gen4.fill") }
            .tag(2)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(3)
        }
        .onAppear {
            #if DEBUG
            // For App Store screenshots: `-ypShotTab recordings` opens on the Recordings tab.
            if UserDefaults.standard.string(forKey: "ypShotTab") == "recordings" { selectedTab = 1 }
            #endif
            #if os(iOS)
            WatchSessionRelay.shared.localScripts = scripts
            #endif
        }
        .onChange(of: scripts) { _, newScripts in
            #if os(iOS)
            WatchSessionRelay.shared.localScripts = newScripts
            #endif
        }
        // A Shortcut, Siri or Spotlight asked for a script: the Scripts tab handles it.
        .onChange(of: AppRouter.shared.pending, initial: true) { _, pending in
            if pending != nil { selectedTab = 0 }
        }
    }
    #endif
}

#Preview {
    ContentView()
        .modelContainer(for: [Script.self, AppSettings.self], inMemory: true)
        .environment(StoreKitService())
}
