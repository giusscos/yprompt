//
//  MenuBarView.swift
//  yprompt
//

#if os(macOS)
import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Bindable private var manager = FloatingTeleprompterManager.shared
    @Bindable private var viewModel = FloatingTeleprompterManager.shared.viewModel
    @State private var selectedScriptID: Script.ID?
    @State private var menuPlaybackMode: Int = 0   // 0=Standard 1=Voice 2=Timer
    @State private var menuTimedMinutes: Int = 3
    @State private var showTimedUpgradeAlert = false
    @State private var showVoiceUpgradeAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                scriptPicker
                modeSelector
                launchButton
                if manager.isVisible {
                    playbackControls
                    fontSizeControl
                    if !manager.notchMode {
                        appearanceControls
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 290)
        .onAppear {
            if selectedScriptID == nil {
                selectedScriptID = manager.currentScript?.id ?? manager.registeredScripts.first?.id
            }
        }
        .onChange(of: manager.registeredScripts) { _, scripts in
            if selectedScriptID == nil {
                selectedScriptID = scripts.first?.id
            }
        }
        .onChange(of: manager.currentScript?.id) { _, newID in
            if let newID {
                selectedScriptID = newID
            }
        }
        .alert("Premium Feature", isPresented: $showTimedUpgradeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Timer mode is available with YPrompt Premium. Open the main app to upgrade.")
        }
        .alert("Premium Feature", isPresented: $showVoiceUpgradeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Voice Scroll is available with YPrompt Premium. Open the main app to upgrade.")
        }
        .alert("Microphone Access Required", isPresented: $viewModel.micPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Voice Scroll needs microphone access to detect when you are speaking.")
        }
    }

    // MARK: - Helpers

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func addCueAtCurrentPosition() {
        guard viewModel.progress > 0, let script = manager.currentScript else { return }
        var cues = script.cuePoints
        let newCue = CuePoint(position: viewModel.progress)
        cues.append(newCue)
        cues.sort { $0.position < $1.position }
        script.cuePoints = cues
        try? script.modelContext?.save()
    }

    private func updateMenuTimedDuration() {
        let total = TimeInterval(menuTimedMinutes * 60)
        viewModel.timedDuration = total > 0 ? total : 180
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Image(systemName: "scroll")
                .foregroundStyle(.tint)
            Text("YPrompt").font(.headline)
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .filter { !($0 is NSPanel) }
                    .first?
                    .makeKeyAndOrderFront(nil)
            } label: {
                Image(systemName: "macwindow")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open main window")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit YPrompt")
        }
        .padding(12)
    }

    // MARK: - Script picker

    private var scriptPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Script")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Picker("Script", selection: Binding(
                get: { selectedScriptID },
                set: { id in
                    selectedScriptID = id
                    if manager.isVisible, let id,
                       let script = manager.registeredScripts.first(where: { $0.id == id }) {
                        manager.show(script: script)
                    }
                }
            )) {
                ForEach(manager.registeredScripts) { script in
                    Text(script.title.isEmpty ? "Untitled" : script.title).tag(Optional(script.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Mode selector

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Mode")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Picker("Mode", selection: $manager.notchMode) {
                Label("Floating", systemImage: "rectangle.on.rectangle").tag(false)
                Label("Notch", systemImage: "camera").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: manager.notchMode) { _, _ in
                if manager.suppressModeRestart {
                    manager.suppressModeRestart = false
                    return
                }
                manager.applyVisibleModeChange()
            }
        }
    }

    // MARK: - Launch / close button

    private var launchButton: some View {
        Button {
            if manager.isVisible {
                manager.hide()
            } else {
                guard let id = selectedScriptID,
                      let script = manager.registeredScripts.first(where: { $0.id == id }) else { return }
                manager.show(script: script)
            }
        } label: {
            Label(
                manager.isVisible ? "Close Teleprompter" : "Show Teleprompter",
                systemImage: manager.isVisible ? "xmark.rectangle" : "play.rectangle.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!manager.isVisible && selectedScriptID == nil)
    }

    // MARK: - Playback controls (visible when teleprompter is open)

    private var playbackControls: some View {
        VStack(spacing: 10) {
            Divider()

            progressSection

            // Play / Pause / Reset row — iOS music-player style
            HStack(spacing: 24) {
                Button { viewModel.resetToTop() } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                .accessibilityLabel("Reset to top")
                .help("Reset to top")

                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                Button { addCueAtCurrentPosition() } label: {
                    Image(systemName: "flag.fill").font(.title2)
                }
                .accessibilityLabel("Add cue point")
                .help("Add cue point at current position")
                .opacity(viewModel.progress > 0 ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .frame(maxWidth: .infinity)

            // Queue autoplay banner / next-in-queue indicator
            if manager.showQueueBanner, let nextScript = manager.nextInQueue {
                queueAutoplayBanner(nextScript: nextScript)
            } else if let nextScript = manager.nextInQueue {
                HStack(spacing: 6) {
                    Image(systemName: "forward.end.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Next: \(nextScript.title.isEmpty ? "Untitled" : nextScript.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }

            // Playback mode selector — iOS camera-app style
            playbackModeSelector

            // Mode-specific controls
            switch menuPlaybackMode {
            case 1:  voiceModeControls
            case 2:  timerModeControls
            default: standardModeControls
            }
        }
    }

    // Progress bar with cue point markers
    private var progressSection: some View {
        VStack(spacing: 4) {
            if let cuePoints = manager.currentScript?.cuePoints, !cuePoints.isEmpty {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        ForEach(cuePoints) { cue in
                            Button {
                                viewModel.jumpToCue(cue)
                            } label: {
                                Image(systemName: "flag.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .offset(x: geo.size.width * CGFloat(cue.position) - 4)
                            .accessibilityLabel(cue.label.isEmpty ? "Cue point" : cue.label)
                        }
                    }
                }
                .frame(height: 14)
            }
            MusicSlider(
                value: Binding(get: { viewModel.progress }, set: { viewModel.seek(to: $0) }),
                range: 0...1
            )
        }
    }

    // MARK: - Playback mode selector

    private var playbackModeSelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Playback mode")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Picker("Playback mode", selection: Binding(
                get: { menuPlaybackMode },
                set: { newMode in
                    if newMode == 1 { guard manager.isPremium else { showVoiceUpgradeAlert = true; return } }
                    if newMode == 2 { guard manager.isPremium else { showTimedUpgradeAlert = true; return } }
                    if newMode != 1 && viewModel.voiceScrollEnabled { Task { await viewModel.toggleVoiceScroll() } }
                    if newMode != 2 { viewModel.timedDuration = nil }
                    if newMode == 2 { updateMenuTimedDuration() }
                    menuPlaybackMode = newMode
                }
            )) {
                Text("Standard").tag(0)
                Text("Voice").tag(1)
                Text("Timer").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Standard — speed slider
    private var standardModeControls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.secondary)
                MusicSlider(
                    value: $viewModel.scrollSpeed,
                    range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                    step: 0.1
                )
                Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
            }
            Text(String(format: "%.1fx speed", viewModel.scrollSpeed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // Voice — mic toggle + level meter
    private var voiceModeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await viewModel.toggleVoiceScroll() }
            } label: {
                Label(
                    viewModel.voiceScrollEnabled ? "Listening…" : "Enable Voice Scroll",
                    systemImage: viewModel.voiceScrollEnabled ? "mic.fill" : "mic"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(viewModel.voiceScrollEnabled ? .green : .accentColor)

            if viewModel.voiceScrollEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.low").font(.caption).foregroundStyle(.secondary)
                    VoiceLevelMeterView(service: viewModel.voiceScrollService)
                    Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.voiceScrollEnabled)
    }

    // Timer — duration picker or countdown
    private var timerModeControls: some View {
        Group {
            if viewModel.isPlaying && viewModel.timedDuration != nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Remaining").font(.caption).foregroundStyle(.secondary)
                    Text(timeString(viewModel.remainingTime))
                        .font(.body.monospacedDigit().bold())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Select time").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        Button {
                            if menuTimedMinutes > 1 { menuTimedMinutes -= 1; updateMenuTimedDuration() }
                        } label: {
                            Image(systemName: "minus").frame(width: 16, height: 16)
                        }
                        Text("\(menuTimedMinutes)m")
                            .font(.body.monospacedDigit().bold())
                            .frame(minWidth: 44)
                        Button {
                            menuTimedMinutes = min(59, menuTimedMinutes + 1)
                            updateMenuTimedDuration()
                        } label: {
                            Image(systemName: "plus").frame(width: 16, height: 16)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Queue autoplay banner

    private func queueAutoplayBanner(nextScript: Script) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "forward.end.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Up next: \(nextScript.title.isEmpty ? "Untitled" : nextScript.title)")
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Text("\(manager.queueCountdown)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(manager.queueCountdown), total: 5)
                .progressViewStyle(.linear)
                .tint(.accentColor)
            HStack(spacing: 8) {
                Button {
                    manager.advanceQueue()
                } label: {
                    Label("Play Now", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    manager.cancelQueueBanner()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Font size control

    private var currentFontSize: CGFloat {
        manager.notchMode ? manager.notchFontSize : manager.floatingFontSize
    }

    private var fontSizeControl: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "textformat.size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("Font Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if manager.notchMode {
                        manager.notchFontSize = max(8, manager.notchFontSize - 1)
                    } else {
                        manager.floatingFontSize = max(12, manager.floatingFontSize - 1)
                    }
                } label: {
                    Image(systemName: "minus").frame(width: 16, height: 16)
                }

                Text("\(Int(currentFontSize))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 26, alignment: .center)

                Button {
                    if manager.notchMode {
                        manager.notchFontSize = min(16, manager.notchFontSize + 1)
                    } else {
                        manager.floatingFontSize = min(40, manager.floatingFontSize + 1)
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
            }
        }
    }

    // MARK: - Appearance controls

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Text("Appearance")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 14)
                MusicSlider(value: $manager.backgroundOpacity, range: 0.15...1.0, step: 0.05)
                Text("\(Int(manager.backgroundOpacity * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Image(systemName: "camera.filters")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 14)
                MusicSlider(value: $manager.blurAmount, range: 0.0...1.0, step: 0.05)
                Text("\(Int(manager.blurAmount * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right.text.vertical")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 14)
                MusicSlider(
                    value: Binding(get: { Double(manager.horizontalPadding) }, set: { manager.horizontalPadding = CGFloat($0) }),
                    range: 0...120,
                    step: 4
                )
                Text("\(Int(manager.horizontalPadding))pt")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }
}
#endif
