//
//  MenuBarView.swift
//  yprompt
//

#if os(macOS)
import AVFoundation
import SwiftUI
import SwiftData

/// The menu bar panel: what's being read and how, in one calm column. The card at the top
/// picks the script and runs the read; the sections below set how it shows, scrolls and records.
struct MenuBarView: View {
    @Bindable private var manager = FloatingTeleprompterManager.shared
    @Bindable private var viewModel = FloatingTeleprompterManager.shared.viewModel
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsArray: [AppSettings]
    @AppStorage("sliderRequiresLongPress") private var sliderRequiresLongPress: Bool = true
    @AppStorage(AppConstants.lyricsStyleKey) private var lyricsStyleEnabled: Bool = true
    @State private var selectedScriptID: Script.ID?
    @AppStorage("menu.playbackMode") private var savedPlaybackMode: Int = 0   // 0=Standard 1=Voice 2=Timer
    @AppStorage("menu.timedMinutes") private var menuTimedMinutes: Int = 3
    @AppStorage("menu.appearanceExpanded") private var appearanceExpanded = false
    @AppStorage(AppConstants.notchAlignmentKey) private var notchAlignment = 0

    private static let contentWidth: CGFloat = 296

    /// Voice and Timer are Pro; the choice is kept in case a lapsed subscription comes back.
    private var menuPlaybackMode: Int { manager.isPremium ? savedPlaybackMode : 0 }

    private var selectedScript: Script? {
        manager.registeredScripts.first { $0.id == selectedScriptID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // No scroll view and no animated height: the menu bar window resizes to fit this,
            // and an animated or scroll-measured height makes AppKit's layout loop until it
            // crashes. Rows appear and disappear in one step instead.
            VStack(spacing: 10) {
                readCard
                displaySection
                scrollingSection
                recordingSection
            }
            // A fixed width, so no control can push the cards past the panel's edges.
            .frame(width: Self.contentWidth)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: Self.contentWidth + 24)
        .fixedSize(horizontal: false, vertical: true)
        .transaction { $0.animation = nil }
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
        .onChange(of: manager.floatingFontSize) { _, size in
            settingsArray.first?.floatingFontSize = size
            try? modelContext.save()
        }
        .onChange(of: manager.notchFontSize) { _, size in
            settingsArray.first?.notchFontSize = size
            try? modelContext.save()
        }
        .onChange(of: manager.notchMode) { _, notch in
            settingsArray.first?.displayMode = notch ? .notch : .floatingWindow
            try? modelContext.save()
            if manager.suppressModeRestart {
                manager.suppressModeRestart = false
                return
            }
            manager.applyVisibleModeChange()
        }
        .onChange(of: viewModel.scrollSpeed) { _, speed in
            // Timer mode works out its own speed, which isn't the reader's choice.
            if menuPlaybackMode == 0 { ReadingPreferences.speed = speed }
        }
        .onChange(of: manager.isVisible) { _, visible in
            if visible && menuPlaybackMode == 2 { updateMenuTimedDuration() }
        }
        .onChange(of: manager.currentScript?.id) { _, newID in
            if let newID {
                selectedScriptID = newID
            }
        }
        .alert(manager.recordMode == .audio ? "Microphone Access Required" : "Camera Access Required",
               isPresented: Binding(get: { manager.capture.permissionDenied },
                                    set: { manager.capture.permissionDenied = $0 })) {
            Button("Open Settings") {
                let pane = manager.recordMode == .audio ? "Privacy_Microphone" : "Privacy_Camera"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To record yourself reading, allow yPrompt to use the camera and microphone in System Settings › Privacy & Security.")
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
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func addCueAtCurrentPosition() {
        guard viewModel.progress > 0, let script = manager.currentScript else { return }
        var cues = script.cuePoints
        cues.append(CuePoint(position: viewModel.progress))
        cues.sort { $0.position < $1.position }
        script.cuePoints = cues
        try? script.modelContext?.save()
    }

    private func updateMenuTimedDuration() {
        let total = TimeInterval(menuTimedMinutes * 60)
        viewModel.timedDuration = total > 0 ? total : 180
    }

    private func present(recording: Bool) {
        guard let script = selectedScript else { return }
        // After this click is done: these buttons are replaced by the playback controls.
        DispatchQueue.main.async {
            if recording && manager.recordMode == .off { manager.recordMode = .camera }
            manager.show(script: script)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text("yPrompt")
                .font(.headline)
            Spacer()
            HeaderIconButton(systemImage: "macwindow", help: "Open main window") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue.hasPrefix(AppConstants.mainWindowID) ?? false
                }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    manager.openMainWindow?()
                }
            }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            HeaderIconButton(systemImage: "power", help: "Quit yPrompt") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Read card

    /// The script and the read itself: pick and start it, then play, record and move through it.
    private var readCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Script", selection: Binding(
                    get: { selectedScriptID },
                    set: { id in
                        selectedScriptID = id
                        if manager.isVisible, let script = selectedScript {
                            DispatchQueue.main.async { manager.show(script: script) }
                        }
                    }
                )) {
                    ForEach(manager.registeredScripts) { script in
                        Text(script.title.isEmpty ? String(localized: "Untitled") : script.title).tag(Optional(script.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                if manager.isVisible {
                    // After this click is done: the button's own row goes away with it.
                    Button { DispatchQueue.main.async { manager.hide() } } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close Teleprompter")
                    .accessibilityLabel("Close Teleprompter")
                }
            }

            if manager.isVisible {
                progressSection
                transport
                queueStatus
            } else {
                HStack(spacing: 8) {
                    Button { present(recording: false) } label: {
                        Label("Present", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { present(recording: true) } label: {
                        Label {
                            Text("Record")
                        } icon: {
                            Image(systemName: "record.circle").foregroundStyle(.red)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(selectedScript == nil)
            }
        }
        .menuCard()
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
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .offset(x: geo.size.width * CGFloat(cue.position) - 4)
                            .accessibilityLabel(cue.label.isEmpty ? "Cue point" : cue.label)
                        }
                    }
                }
                .frame(height: 12)
            }
            MusicSlider(
                value: Binding(get: { viewModel.progress }, set: { viewModel.seek(to: $0) }),
                range: 0...1,
                requiresLongPress: sliderRequiresLongPress,
                accessibilityTitle: Text("Position")
            )
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            TransportButton(systemImage: "backward.end.fill", label: "Reset to top") { viewModel.resetToTop() }
                .frame(maxWidth: .infinity)

            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
            .frame(maxWidth: .infinity)

            if manager.recordMode != .off {
                recordButton
                    .frame(maxWidth: .infinity)
            }

            TransportButton(systemImage: "flag.fill", label: "Add cue point") { addCueAtCurrentPosition() }
                .opacity(viewModel.progress > 0 ? 1 : 0.35)
                .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            if manager.capture.isRecording, let start = manager.capture.recordingStartDate {
                RecordingBadge(start: start)
                    .offset(y: -6)
                    .transition(.opacity)
            }
        }
    }

    private var recordButton: some View {
        let isRecording = manager.capture.isRecording
        return Button { manager.toggleRecording() } label: {
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.6), lineWidth: 2)
                    .frame(width: 34, height: 34)
                RoundedRectangle(cornerRadius: isRecording ? 3 : 12)
                    .fill(.red)
                    .frame(width: isRecording ? 13 : 24, height: isRecording ? 13 : 24)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
        .help(isRecording ? "Stop Recording" : "Start Recording")
    }

    @ViewBuilder
    private var queueStatus: some View {
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
    }

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
                Button { manager.advanceQueue() } label: {
                    Label("Play Now", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { manager.cancelQueueBanner() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Display

    private var displaySection: some View {
        MenuSection("Display", systemImage: "macwindow") {
            Picker("Mode", selection: Binding(
                get: { manager.notchMode },
                set: { notch in
                    guard !notch || manager.isPremium else {
                        manager.showPaywall()
                        return
                    }
                    manager.notchMode = notch
                }
            )) {
                Text("Floating").tag(false)
                Text(manager.isPremium ? "Notch" : "Notch 🔒").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            MenuRow("Text Size", systemImage: "textformat.size") {
                fontSizeStepper
            }

            if manager.notchMode {
                MenuRow("Scroll Vertically", systemImage: "arrow.up.and.down.text.horizontal") {
                    Toggle("Scroll Vertically", isOn: Binding(
                        get: { settingsArray.first?.notchScrollVertical ?? manager.notchScrollVertical },
                        set: { value in
                            if let settings = settingsArray.first {
                                settings.notchScrollVertical = value
                                try? modelContext.save()
                            }
                            manager.setNotchScrollVertical(value)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                if manager.notchScrollVertical {
                    MenuRow("Alignment", systemImage: "text.alignleft") {
                        Picker("Alignment", selection: $notchAlignment) {
                            Image(systemName: "text.alignleft").tag(0)
                                .accessibilityLabel("Left")
                            Image(systemName: "text.aligncenter").tag(1)
                                .accessibilityLabel("Center")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } else {
                Button {
                    appearanceExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "paintbrush")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text("Appearance")
                            .font(.callout)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(appearanceExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if appearanceExpanded {
                    VStack(spacing: 8) {
                        sliderRow(icon: "circle.lefthalf.filled", title: "Background",
                                  value: $manager.backgroundOpacity, range: 0.15...1.0, step: 0.05,
                                  valueText: "\(Int(manager.backgroundOpacity * 100))%")
                        sliderRow(icon: "camera.filters", title: "Blur",
                                  value: $manager.blurAmount, range: 0...1, step: 0.05,
                                  valueText: "\(Int(manager.blurAmount * 100))%")
                        sliderRow(icon: "arrow.left.and.right.text.vertical", title: "Margins",
                                  value: Binding(get: { Double(manager.horizontalPadding) },
                                                 set: { manager.horizontalPadding = CGFloat($0) }),
                                  range: 0...120, step: 4,
                                  valueText: "\(Int(manager.horizontalPadding))pt")
                    }
                }
            }
        }
    }

    private var currentFontSize: CGFloat {
        manager.notchMode ? manager.notchFontSize : manager.floatingFontSize
    }

    private func changeFontSize(by delta: CGFloat) {
        // The notch and the floating window animate the change themselves.
        if manager.notchMode {
            manager.notchFontSize = min(32, max(8, manager.notchFontSize + delta))
        } else {
            manager.floatingFontSize = min(40, max(12, manager.floatingFontSize + delta))
        }
    }

    private var fontSizeStepper: some View {
        HStack(spacing: 0) {
            Button { changeFontSize(by: -1) } label: {
                Image(systemName: "minus").frame(width: 26, height: 22).contentShape(Rectangle())
            }
            .accessibilityLabel("Smaller Text")
            Text("\(Int(currentFontSize))")
                .font(.callout.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
                .frame(width: 28)
            Button { changeFontSize(by: 1) } label: {
                Image(systemName: "plus").frame(width: 26, height: 22).contentShape(Rectangle())
            }
            .accessibilityLabel("Larger Text")
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.7), in: Capsule())
    }

    private func sliderRow(icon: String, title: LocalizedStringKey, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double, valueText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption).foregroundStyle(.secondary).frame(width: 16)
            MusicSlider(
                value: value, range: range, step: step,
                requiresLongPress: sliderRequiresLongPress,
                accessibilityTitle: Text(title),
                accessibilityValueText: Text(verbatim: valueText)
            )
            Text(verbatim: valueText)
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - Scrolling

    private var scrollingSection: some View {
        MenuSection("Scrolling", systemImage: "text.line.first.and.arrowtriangle.forward") {
            Picker("Playback mode", selection: Binding(
                get: { menuPlaybackMode },
                set: { newMode in
                    if newMode != 0 { guard manager.isPremium else { manager.showPaywall(); return } }
                    if newMode != 1 && viewModel.voiceScrollEnabled { Task { await viewModel.toggleVoiceScroll() } }
                    if newMode != 2 { viewModel.timedDuration = nil }
                    if newMode == 2 { updateMenuTimedDuration() }
                    savedPlaybackMode = newMode
                }
            )) {
                Text("Standard").tag(0)
                Text(manager.isPremium ? "Voice" : "Voice 🔒").tag(1)
                Text(manager.isPremium ? "Timer" : "Timer 🔒").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch menuPlaybackMode {
            case 1:  voiceModeControls
            case 2:  timerModeControls
            default: standardModeControls
            }

            Group {
                MenuRow(manager.isPremium ? "Lyrics Style" : "Lyrics Style 🔒", systemImage: "music.note.list") {
                    Toggle("Lyrics Style", isOn: Binding(
                        get: { lyricsStyleEnabled && manager.isPremium || viewModel.voiceScrollEnabled },
                        set: { enabled in
                            guard manager.isPremium else {
                                manager.showPaywall()
                                return
                            }
                            lyricsStyleEnabled = enabled
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(viewModel.voiceScrollEnabled)
                }
            }
        }
    }

    private var standardModeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.secondary)
            MusicSlider(
                value: $viewModel.scrollSpeed,
                range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                step: 0.1,
                requiresLongPress: sliderRequiresLongPress,
                accessibilityTitle: Text("Speed"),
                accessibilityValueText: Text(String(format: "%.1f×", viewModel.scrollSpeed))
            )
            Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f×", viewModel.scrollSpeed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var voiceModeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await viewModel.toggleVoiceScroll() }
            } label: {
                Label(
                    viewModel.voiceScrollEnabled ? "Listening…" : "Enable Voice Scroll",
                    systemImage: viewModel.voiceScrollEnabled ? "mic.fill" : "mic"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(viewModel.voiceScrollEnabled ? .green : .accentColor)
            // Listening only makes sense with something on screen to follow.
            .disabled(!manager.isVisible)

            if viewModel.voiceScrollEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.low").font(.caption).foregroundStyle(.secondary)
                    VoiceLevelMeterView(service: viewModel.voiceScrollService)
                    Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary)
                }

            }
        }

    }

    @ViewBuilder
    private var timerModeControls: some View {
        if viewModel.isPlaying && viewModel.timedDuration != nil {
            MenuRow("Remaining", systemImage: "timer") {
                Text(timeString(viewModel.remainingTime))
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
        } else {
            MenuRow("Duration", systemImage: "timer") {
                HStack(spacing: 0) {
                    Button {
                        if menuTimedMinutes > 1 { menuTimedMinutes -= 1; updateMenuTimedDuration() }
                    } label: {
                        Image(systemName: "minus").frame(width: 26, height: 22).contentShape(Rectangle())
                    }
                    .accessibilityLabel("One Minute Less")
                    Text("\(menuTimedMinutes)m")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .frame(minWidth: 36)
                    Button {
                        menuTimedMinutes = min(59, menuTimedMinutes + 1)
                        updateMenuTimedDuration()
                    } label: {
                        Image(systemName: "plus").frame(width: 26, height: 22).contentShape(Rectangle())
                    }
                    .accessibilityLabel("One Minute More")
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.7), in: Capsule())
            }
        }
    }

    // MARK: - Recording

    private var recordingSection: some View {
        MenuSection("Record", systemImage: "record.circle") {
            Picker("Record", selection: $manager.recordMode) {
                Text("Off").tag(FloatingTeleprompterManager.RecordMode.off)
                Text("Camera").tag(FloatingTeleprompterManager.RecordMode.camera)
                Text("Audio").tag(FloatingTeleprompterManager.RecordMode.audio)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(manager.capture.isRecording)

            if manager.recordMode == .camera {
                if manager.capture.cameras.count > 1 {
                    MenuRow("Camera", systemImage: "video") {
                        Picker("Camera", selection: Binding(
                            get: { manager.capture.selectedCamera?.uniqueID ?? "" },
                            set: { id in
                                if let device = manager.capture.cameras.first(where: { $0.uniqueID == id }) {
                                    manager.capture.selectCamera(device)
                                }
                            }
                        )) {
                            ForEach(manager.capture.cameras, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(device.uniqueID)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 160)
                        .disabled(manager.capture.isRecording)
                    }
                }
                MenuRow("Show Camera Preview", systemImage: "pip") {
                    Toggle("Show Camera Preview", isOn: $manager.showsCameraPreview)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                MenuRow("Mirror Camera", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    Toggle("Mirror Camera", isOn: $manager.mirrorsCamera)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
        }
    }
}

// MARK: - Building blocks

/// A titled group of settings on a soft card.
private struct MenuSection<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            content
        }
        .menuCard()
    }
}

/// A setting on one line: what it is on the left, its control on the right.
private struct MenuRow<Control: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let control: Control

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 24)
    }
}

private struct HeaderIconButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TransportButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
        .help(label)
    }
}

private extension View {
    func menuCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
    }
}
#endif
