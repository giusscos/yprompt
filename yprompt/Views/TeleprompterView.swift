//
//  TeleprompterView.swift
//  yprompt
//

import SwiftUI
import SwiftData
import StoreKit
#if os(iOS)
import AVFoundation
#endif

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

#if os(iOS)
private struct PanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
#endif

struct MusicSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var requiresLongPress: Bool = true

    @GestureState private var isDragging = false
    @State private var localValue: Double? = nil
    @State private var confirmTask: Task<Void, Never>? = nil
    @State private var confirmed = false
    @State private var impactOnStart = false
    @State private var impactOnConfirm = false

    private var displayValue: Double { localValue ?? value }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? CGFloat((displayValue - range.lowerBound) / span) : 0
            let trackHeight: CGFloat = isDragging ? 8 : 4

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.2))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.primary.opacity(0.65))
                    .frame(width: max(0, fraction * width), height: trackHeight)
                    // Fill progresses toward target over 1 s, matching the confirmation delay
                    .animation(.linear(duration: 1.0), value: localValue)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        let newFrac = max(0, min(1, gesture.location.x / width))
                        var newValue = range.lowerBound + Double(newFrac) * span
                        if let s = step, s > 0 {
                            newValue = (newValue / s).rounded() * s
                        }
                        let clamped = max(range.lowerBound, min(range.upperBound, newValue))
                        if !requiresLongPress {
                            // Immediate mode: apply value directly without confirmation delay
                            value = clamped
                            var t = Transaction(animation: nil)
                            t.disablesAnimations = true
                            withTransaction(t) { localValue = clamped }
                        } else if confirmed {
                            // Post-confirmation: seek instantly, no animation lag
                            value = clamped
                            var t = Transaction(animation: nil)
                            t.disablesAnimations = true
                            withTransaction(t) { localValue = clamped }
                        } else {
                            // Pre-confirmation: update target; modifier animates fill over 1 s
                            localValue = clamped
                            if confirmTask == nil {
                                impactOnStart.toggle()
                                confirmTask = Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1))
                                    guard !Task.isCancelled else { return }
                                    confirmed = true
                                    impactOnConfirm.toggle()
                                    if let lv = localValue { value = lv }
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        if !confirmed {
                            confirmTask?.cancel()
                            // Snap fill back instantly — no rewind animation
                            var t = Transaction(animation: nil)
                            t.disablesAnimations = true
                            withTransaction(t) { localValue = nil }
                        } else {
                            localValue = nil
                        }
                        confirmTask = nil
                        confirmed = false
                    }
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
        }
        .frame(height: 28)
#if os(iOS)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: impactOnStart)
        .sensoryFeedback(.impact(weight: .medium), trigger: impactOnConfirm)
#endif
    }
}

#if os(iOS)
private enum TeleprompterMode: String, CaseIterable {
    case auto   = "Auto"
    case tap    = "Tap"
    case voice  = "Voice"
    case timed  = "Timed"

    var icon: String {
        switch self {
        case .auto:   return "scroll"
        case .tap:    return "hand.tap.fill"
        case .voice:  return "mic"
        case .timed:  return "timer"
        }
    }
}

private enum BackgroundMode: Hashable {
    case solidColor
    case camera
}
#endif

struct TeleprompterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var queueScripts: [Script]
    @State private var queueIndex: Int = 0
    @State private var viewModel = TeleprompterViewModel()
#if os(iOS)
    @StateObject private var cameraService = CameraRecordingService()
#endif
#if !os(watchOS)
    @Environment(StoreKitService.self) private var storeKit
    @State private var showingPaywall = false
    @Environment(\.requestReview) private var requestReview
#endif
#if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isPlayerExpanded: Bool = true
    @State private var isSheetPresented: Bool = true
    @State private var liveHorizontalPadding: CGFloat = 16
    @State private var teleprompterMode: TeleprompterMode = .auto
    @Namespace private var modeNamespace
    @State private var backgroundMode: BackgroundMode = .solidColor
    @State private var fullPanelHeight: CGFloat = 280
    @AppStorage("sliderRequiresLongPress") private var sliderRequiresLongPress: Bool = true
    @State private var showNextBanner = false
    @State private var nextCountdown = 5
    @State private var countdownTask: Task<Void, Never>? = nil
    @State private var timedMinutes: Int = 3
    @State private var timedSeconds: Int = 0
    @State private var resetCuePointsPrompt: Bool = false
    @State private var liveFontSize: CGFloat = AppConstants.defaultFontSize
    @State private var lastCrossedCueProgress: Double = -1
    @State private var showDisplayAdjustments = false
    @State private var isExitingPlayMode = false
    @State private var didRestoreTabBar = false
    @State private var didRestoreProgress = false
#endif
#if !os(watchOS) && !os(iOS)
    @State private var macTimedEnabled = false
    @State private var macTimedMinutes: Int = 3
#endif

    private var currentScript: Script { queueScripts[queueIndex] }
    private var nextQueueScript: Script? { queueIndex + 1 < queueScripts.count ? queueScripts[queueIndex + 1] : nil }
    private var customization: TextCustomization { currentScript.customization }
    
    init(script: Script) {
        _queueScripts = State(initialValue: [script])
    }
    
    init(queue: [Script]) {
        _queueScripts = State(initialValue: queue)
    }
    
#if os(iOS)
    private var contentBackground: Color {
        cameraService.isCameraActive ? .clear : Color(hex: customization.backgroundColorHex)
    }

    private var isBackgroundDark: Bool {
        if cameraService.isCameraActive { return true }
        let uiColor = UIColor(Color(hex: customization.backgroundColorHex))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        return 0.299 * r + 0.587 * g + 0.114 * b < 0.5
    }

    private var miniDetentHeight: CGFloat { 72 }
    /// Drag indicator + a little breathing room above home indicator.
    private var sheetHeightPadding: CGFloat { 10 }
    private var fullDetentHeight: CGFloat {
        let fitted = fullPanelHeight + sheetHeightPadding
        return verticalSizeClass == .compact ? min(fitted, 260) : fitted
    }
    private var activeSheetHeight: CGFloat { isPlayerExpanded ? fullDetentHeight : miniDetentHeight }
    private var sheetMorphAnimation: Animation { .spring(response: 0.38, dampingFraction: 0.86) }
#endif
    
    var body: some View {
#if os(iOS)
        iOSBody
#else
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        scrollingContent(screenSize: geo.size)
                            .clipped()
                            .onAppear {
                                viewModel.screenHeight = geo.size.height
                                viewModel.scrollSpeed = customization.scrollSpeed
                                viewModel.transparency = customization.transparency
                            }
                    }
                    .onTapGesture {
                        if viewModel.isTapToAdvance { viewModel.tapAdvance() }
                    }
                    
#if !os(watchOS)
                    Group {
                        if viewModel.voiceScrollEnabled && viewModel.showVoiceMeter {
                            voiceMeterRow
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.voiceScrollEnabled && viewModel.showVoiceMeter)
#endif
                    
                    controlBar
                }
                .background(Color(hex: customization.backgroundColorHex))
                .opacity(viewModel.transparency)
            }
            .toolbar {
#if os(macOS)
                ToolbarItem(placement: .automatic) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline)
                    }
                }
#endif
            }
#if !os(watchOS)
            .onKeyPress(.space) { viewModel.togglePlayPause(); return .handled }
            .onKeyPress(.upArrow) {
                viewModel.scrollSpeed = min(viewModel.scrollSpeed + 0.1, AppConstants.maxScrollSpeed)
                return .handled
            }
            .onKeyPress(.downArrow) {
                viewModel.scrollSpeed = max(viewModel.scrollSpeed - 0.1, AppConstants.minScrollSpeed)
                return .handled
            }
            .onKeyPress(KeyEquivalent("r")) { viewModel.resetToTop(); return .handled }
            .sheet(isPresented: $showingPaywall) {
                PaywallView().environment(storeKit)
            }
            .alert("Microphone Access Required", isPresented: $viewModel.micPermissionDenied) {
                Button("Open Settings") { openMicSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Voice Scroll needs microphone access to detect when you are speaking.")
            }
            .onChange(of: viewModel.isFinished) { _, finished in
                guard finished else { return }
                currentScript.lastProgress = 1.0
                try? modelContext.save()
                RatingService.shared.recordSessionCompleted()
                if RatingService.shared.shouldRequestReview {
                    RatingService.shared.markReviewRequested()
                    requestReview()
                }
            }
#if !os(iOS)
            .onChange(of: viewModel.contentHeight) { _, newHeight in
                guard !didRestoreProgress, newHeight > 0, viewModel.screenHeight > 0 else { return }
                didRestoreProgress = true
                let p = currentScript.lastProgress
                if p > 0 && p < 1 { viewModel.seek(to: p) }
            }
#endif
            .onDisappear { saveLastProgress() }
#endif
        }
#endif
    }
    
    // MARK: - iOS Body (Music Player Layout)
    
#if os(iOS)
    private var iOSBody: some View {
        TeleprompterScrollView(
            offset: $viewModel.contentOffset,
            content: textBody(textColor: cameraService.isCameraActive ? .white : nil, horizontalPadding: liveHorizontalPadding),
            onHeights: { contentHeight, screenHeight in
                print("[Queue] onHeights — contentHeight=\(Int(contentHeight)) screenHeight=\(Int(screenHeight))")
                viewModel.contentHeight = contentHeight
                // screenHeight is full height below nav bar; subtract the sheet so maxOffset
                // reflects only the readable area above the sheet.
                viewModel.screenHeight = max(100, screenHeight - (isSheetPresented ? activeSheetHeight : 0))
                // Restore saved scroll position once layout is ready (only on first load, not queue advances).
                if !didRestoreProgress && contentHeight > 0 {
                    didRestoreProgress = true
                    let p = currentScript.lastProgress
                    if p > 0 && p < 1 { viewModel.seek(to: p) }
                }
                // After a queue advance, UIKit fires one stale layout with the old script's height
                // before the new content is measured. Only start playing once a different (real)
                // height arrives — the 200 ms Task in advanceToNextScript handles the same-height edge case.
                if viewModel.pendingAutoPlay && contentHeight > 0 && contentHeight != viewModel.pendingAutoPlayStaleHeight {
                    viewModel.pendingAutoPlay = false
                    viewModel.play()
                }
            },
            bottomInset: isSheetPresented ? activeSheetHeight : 0,
            scriptID: currentScript.id,
            fontSize: liveFontSize,
            horizontalPadding: liveHorizontalPadding
        )
        .ignoresSafeArea()
        .background {
            if let session = cameraService.captureSession {
                ZStack {
                    CameraPreviewRepresentable(session: session, verticalSizeClass: verticalSizeClass)
                        .ignoresSafeArea()
                    Color.black.opacity(0.42)
                        .ignoresSafeArea()
                }
                .allowsHitTesting(false)
            } else if backgroundMode == .camera {
                #if DEBUG
                ZStack {
                    Image("CameraDemoBackground")
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                    Color.black.opacity(0.42)
                        .ignoresSafeArea()
                }
                .allowsHitTesting(false)
                #else
                contentBackground.ignoresSafeArea()
                #endif
            } else {
                contentBackground.ignoresSafeArea()
            }
        }
        .onAppear {
            viewModel.scrollSpeed = customization.scrollSpeed
            viewModel.transparency = customization.transparency
            liveFontSize = customization.fontSize
        }
        .onTapGesture {
            if viewModel.isTapToAdvance { viewModel.tapAdvance() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .background(NavigationInteractivePopGestureDisabler(disabled: true))
        .toolbarColorScheme(isBackgroundDark ? .dark : .light, for: .navigationBar)
        .toolbar { iOSToolbar }
        .onChange(of: verticalSizeClass) { _, newValue in
            if newValue != .compact && !isExitingPlayMode { isSheetPresented = true }
        }
        .opacity(viewModel.transparency)
        .safeAreaInset(edge: .top, spacing: 0) {
            if showNextBanner, let next = nextQueueScript {
                nextScriptBanner(for: next)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .sheet(isPresented: $isSheetPresented) {
            iOSPlayerPanel
                .onPreferenceChange(PanelContentHeightKey.self) { h in
                    guard isPlayerExpanded, h > 0, abs(h - fullPanelHeight) > 1 else { return }
                    withAnimation(sheetMorphAnimation) {
                        fullPanelHeight = h
                    }
                }
                .presentationDetents(
                    [.height(miniDetentHeight), .height(fullDetentHeight)],
                    selection: Binding(
                        get: { isPlayerExpanded ? .height(fullDetentHeight) : .height(miniDetentHeight) },
                        set: { isPlayerExpanded = $0 != .height(miniDetentHeight) }
                    )
                )
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(fullDetentHeight)))
                .interactiveDismissDisabled(verticalSizeClass != .compact)
                // Presented from the sheet so the player sheet stays visible underneath.
                .popover(isPresented: $showDisplayAdjustments, arrowEdge: .bottom) {
                    displayAdjustmentsPopover
                        .padding()
                        .frame(minWidth: 280)
                        .presentationCompactAdaptation(.popover)
                }
        }
        .onChange(of: isSheetPresented) { _, presented in
            if !presented { showDisplayAdjustments = false }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView().environment(storeKit)
        }
        .alert("Microphone Access Required", isPresented: $viewModel.micPermissionDenied) {
            Button("Open Settings") { openMicSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Voice Scroll needs microphone access to detect when you are speaking.")
        }
        .alert("Camera & Microphone Access Required", isPresented: $cameraService.permissionDenied) {
            Button("Open Settings") { openMicSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Camera mode needs camera and microphone access to record video.")
        }
        .alert("Recording Saved", isPresented: $cameraService.recordingSaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your recording has been saved to the Photos library.")
        }
        .onChange(of: cameraService.permissionDenied) { _, denied in
            if denied { withAnimation { backgroundMode = .solidColor } }
        }
        .alert("Reset Cue Points?", isPresented: $resetCuePointsPrompt) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { performResetCuePoints() }
        } message: {
            Text("This will remove all cue points for the current script.")
        }
        .onChange(of: viewModel.isFinished) { _, finished in
            guard finished else { return }
            currentScript.lastProgress = 1.0
            try? modelContext.save()
            RatingService.shared.recordSessionCompleted()
            if nextQueueScript != nil {
                showNextBanner = true
                startNextCountdown()
            } else if RatingService.shared.shouldRequestReview {
                RatingService.shared.markReviewRequested()
                requestReview()
            }
        }
        .onChange(of: liveFontSize) { _, newSize in
            var c = currentScript.customization
            c.fontSize = newSize
            currentScript.customization = c
            try? modelContext.save()
        }
        .onChange(of: viewModel.progress) { oldProgress, newProgress in
            guard viewModel.isPlaying, !currentScript.cuePoints.isEmpty else { return }
            let crossed = currentScript.cuePoints.contains {
                $0.position > oldProgress && $0.position <= newProgress
            }
            if crossed { WatchSessionRelay.shared.sendHapticCue() }
        }
        .onAppear(perform: handlePlayModeAppear)
        .onDisappear(perform: handlePlayModeDisappear)
        .onChange(of: timedMinutes) { _, _ in updateTimedDuration() }
        .onChange(of: timedSeconds) { _, _ in updateTimedDuration() }
    }

    @ToolbarContentBuilder
    private var iOSToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                exitPlayMode()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Back")
            .disabled(isExitingPlayMode)
        }
        if verticalSizeClass == .compact && !isSheetPresented {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isSheetPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.below.rectangle")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    selectBackground(.solidColor)
                } label: {
                    Label("Color", systemImage: "paintpalette.fill")
                    if backgroundMode == .solidColor {
                        Image(systemName: "checkmark")
                    }
                }
                Button {
                    selectBackground(.camera)
                } label: {
                    Label("Camera", systemImage: "camera.fill")
                    if backgroundMode == .camera {
                        Image(systemName: "checkmark")
                    }
                }
            } label: {
                Image(systemName: backgroundMode == .camera ? "camera.fill" : "paintpalette.fill")
            }
            .accessibilityLabel("Background")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if isSheetPresented {
                    showDisplayAdjustments.toggle()
                } else {
                    isPlayerExpanded = true
                    isSheetPresented = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        showDisplayAdjustments = true
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .symbolVariant(showDisplayAdjustments ? .fill : .none)
            }
            .accessibilityLabel("Display adjustments")
        }
    }

    private func handlePlayModeAppear() {
        TabBarAnimator.setHidden(true, animated: true)
        WatchSessionRelay.shared.onCommandReceived = { command in
            handleWatchCommand(command)
        }
    }

    private func handlePlayModeDisappear() {
        if !didRestoreTabBar {
            didRestoreTabBar = true
            TabBarAnimator.setHidden(false, animated: true)
        }
        saveLastProgress()
        cameraService.stopCamera()
        countdownTask?.cancel()
        WatchSessionRelay.shared.onCommandReceived = nil
    }

    private func handleWatchCommand(_ command: RemoteControlCommand) {
        switch command {
        case .startContinuousDown:  viewModel.startContinuousScroll(direction: .forward)
        case .startContinuousUp:    viewModel.startContinuousScroll(direction: .backward)
        case .stopContinuous:       viewModel.stopContinuousScroll()
        case .togglePlayPause:      viewModel.togglePlayPause()
        case .reset:                viewModel.resetToTop()
        case .setSpeed(let speed):
            viewModel.scrollSpeed = max(AppConstants.minScrollSpeed, min(AppConstants.maxScrollSpeed, speed))
        case .selectScript:
            break
        case .setNotchMode:
            break
        case .setVoiceScroll(let enabled):
            Task {
                if enabled != viewModel.voiceScrollEnabled {
                    await viewModel.toggleVoiceScroll()
                }
            }
        case .setTimedDuration(let duration):
            viewModel.timedDuration = duration
        }
    }
    
    private func exitPlayMode() {
        guard !isExitingPlayMode else { return }
        isExitingPlayMode = true
        showDisplayAdjustments = false

        Task { @MainActor in
            if isSheetPresented {
                isSheetPresented = false
                // Let the player sheet finish sliding away before leaving play mode.
                try? await Task.sleep(for: .milliseconds(400))
            }
            didRestoreTabBar = true
            TabBarAnimator.setHidden(false, animated: true)
            dismiss()
        }
    }

    private func updateTimedDuration() {
        guard teleprompterMode == .timed else { return }
        let total = TimeInterval(timedMinutes * 60 + timedSeconds)
        viewModel.timedDuration = total > 0 ? total : 180
    }
    
    private var iOSPlayerPanel: some View {
        VStack(spacing: 0) {
            if isPlayerExpanded {
                iOSFullPanel
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                    ))
            } else {
                iOSCompactPanel
                    .transition(.opacity)
            }
        }
        .animation(sheetMorphAnimation, value: isPlayerExpanded)
    }
    
    // Compact strip shown when sheet is minimised
    private var iOSCompactPanel: some View {
        HStack(spacing: 30) {
            HStack (spacing: 24) {
                Button { viewModel.resetToTop() } label: {
                    Image(systemName: "backward.end.fill").font(.title3)
                }
                .accessibilityLabel("Reset to top")

                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
            }
            
            MusicSlider(
                value: Binding(get: { viewModel.progress }, set: { viewModel.seek(to: $0) }),
                range: 0...1,
                requiresLongPress: sliderRequiresLongPress
            )
        }
        .padding(.horizontal)
        .tint(.primary)
    }
    
    // Full music-player panel
    private var iOSFullPanel: some View {
        VStack(spacing: 16) {
            VStack(spacing: 2) {
                Text(currentScript.title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                if teleprompterMode == .timed && viewModel.timedDuration != nil {
                    Text(timeString(viewModel.remainingTime))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: viewModel.remainingTime)
                } else {
                    Text(String(format: "%d%%", Int(viewModel.progress * 100)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: Int(viewModel.progress * 100))
                }
            }
            
            VStack(spacing: 2) {
                // Cue point markers strip (moved above the progress bar)
                if !currentScript.cuePoints.isEmpty {
                    cuePointStrip
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                MusicSlider(
                    value: Binding(get: { viewModel.progress }, set: { viewModel.seek(to: $0) }),
                    range: 0...1,
                    requiresLongPress: sliderRequiresLongPress
                )
            }
            
            HStack(spacing: 24) {
                Button { viewModel.resetToTop() } label: {
                    Image(systemName: "restart").font(.title2)
                }
                .accessibilityLabel("Reset to top")
                
                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
                
                // Right side: record (camera mode), add cue, or spacer
                if backgroundMode == .camera {
                    Button { cameraService.toggleRecording() } label: {
                        Image(systemName: cameraService.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                            .foregroundStyle(cameraService.isRecording ? .red : .primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(cameraService.isRecording ? "Stop Recording" : "Start Recording")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button { addCueAtCurrentPosition() } label: {
                        Image(systemName: "flag.fill").font(.title2)
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.6)
                            .onEnded { _ in
                                // Long-press: ask to reset all cue points
                                resetCuePointsPrompt = true
                            }
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            performResetCuePoints()
                        } label: {
                            Label("Reset Cue Points", systemImage: "flag.slash.fill")
                        }
                    }
                    .accessibilityLabel("Add Cue Point")
                    .opacity(viewModel.progress > 0 ? 1 : 0.3)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            
            if teleprompterMode == .timed {
                timedControls
                    .transition(.blurReplace.combined(with: .opacity))
            }
            
            // Voice meter — contextual, only in voice mode
            if teleprompterMode == .voice && viewModel.voiceScrollEnabled && viewModel.showVoiceMeter {
                VoiceLevelMeterView(service: viewModel.voiceScrollService, showStatus: true)
                    .transition(.blurReplace.combined(with: .opacity))
            }
            
            modeSelector
                .padding(.bottom)
        }
        .tint(.primary)
        .padding()
        // Hug intrinsic height so the sheet detent can follow content (avoids GeometryReader filling the detent).
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: PanelContentHeightKey.self, value: geo.size.height)
            }
        }
        .animation(sheetMorphAnimation, value: teleprompterMode)
        .animation(sheetMorphAnimation, value: backgroundMode == .camera)
        .animation(sheetMorphAnimation, value: viewModel.showVoiceMeter)
    }
    
    private var displayAdjustmentsPopover: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.secondary)
                    MusicSlider(
                        value: $viewModel.scrollSpeed,
                        range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                        step: 0.1,
                        requiresLongPress: false
                    )
                    Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
                }
                Text(String(format: String(localized: "%.1fx speed"), viewModel.scrollSpeed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: viewModel.scrollSpeed)
            }
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                        .font(.caption).foregroundStyle(.secondary)
                    MusicSlider(
                        value: Binding(
                            get: { Double(liveHorizontalPadding) },
                            set: { liveHorizontalPadding = CGFloat($0) }
                        ),
                        range: 0...80,
                        step: 4,
                        requiresLongPress: false
                    )
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(String(format: String(localized: "%.0fpx margins"), liveHorizontalPadding))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: liveHorizontalPadding)
            }
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.caption).foregroundStyle(.secondary)
                    MusicSlider(
                        value: Binding(
                            get: { Double(liveFontSize) },
                            set: { liveFontSize = CGFloat($0) }
                        ),
                        range: Double(AppConstants.minFontSize)...Double(AppConstants.maxFontSize),
                        step: 1,
                        requiresLongPress: false
                    )
                    Image(systemName: "textformat.size.larger")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(String(format: String(localized: "%dpt font"), Int(liveFontSize)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: liveFontSize)
            }
        }
        .tint(.primary)
    }
    
    // MARK: - Cue Points
    
    private var cuePointStrip: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(currentScript.cuePoints) { cue in
                    Button {
                        viewModel.jumpToCue(cue)
                    } label: {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .offset(x: geo.size.width * CGFloat(cue.position) - 4)
                    .accessibilityLabel(cue.label.isEmpty ? "Cue point" : cue.label)
                }
            }
        }
        .frame(height: 16)
    }
    
    private func addCueAtCurrentPosition() {
        guard viewModel.progress > 0 else { return }
        var cues = currentScript.cuePoints
        let newCue = CuePoint(position: viewModel.progress)
        cues.append(newCue)
        cues.sort { $0.position < $1.position }
        currentScript.cuePoints = cues
        try? modelContext.save()
    }
    
    private func performResetCuePoints() {
        guard !currentScript.cuePoints.isEmpty else { return }
        currentScript.cuePoints = []
        try? modelContext.save()
    }
    
    // MARK: - Timed Controls

    @ViewBuilder
    private var timedControls: some View {
        if viewModel.isPlaying && viewModel.timedDuration != nil {
            timedProgressRow
        } else {
            timedSetupRow
        }
    }

    private var timedSetupRow: some View {
        HStack {
            Image(systemName: "timer").foregroundStyle(.secondary)
            Text("Duration").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 0) {
                Button { stepTimedDuration(by: -30) } label: {
                    Image(systemName: "minus")
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Text(timedDurationString)
                    .font(.body.monospacedDigit().bold())
                    .frame(minWidth: 64, alignment: .center)
                    .contentTransition(.numericText())
                    .animation(.default, value: timedDurationString)
                Button { stepTimedDuration(by: 30) } label: {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .buttonStyle(.plain)
            .tint(.primary)
        }
    }

    @ViewBuilder
    private var timedProgressRow: some View {
        let total = viewModel.timedDuration ?? 180
        let fraction = total > 0 ? min(1.0, (total - viewModel.remainingTime) / total) : 0.0
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: fraction)
                Image(systemName: "timer")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Remaining")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(timeString(viewModel.remainingTime))
                    .font(.body.monospacedDigit().bold())
                    .contentTransition(.numericText())
                    .animation(.default, value: viewModel.remainingTime)
            }

            Spacer()

            Text("/ \(timedDurationString)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var timedDurationString: String {
        "\(timedMinutes):\(String(format: "%02d", timedSeconds))"
    }

    private func stepTimedDuration(by seconds: Int) {
        var total = timedMinutes * 60 + timedSeconds + seconds
        total = max(30, min(59 * 60 + 30, (total / 30) * 30))
        timedMinutes = total / 60
        timedSeconds = total % 60
    }
    
    // MARK: - Mode selector
    
    private var modeSelector: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 0) {
                        ForEach(TeleprompterMode.allCases, id: \.self) { mode in
                            modeSelectorItem(mode)
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(TeleprompterMode.allCases, id: \.self) { mode in
                        modeSelectorItem(mode)
                    }
                }
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
    
    @ViewBuilder
    private func modeSelectorItem(_ mode: TeleprompterMode) -> some View {
        if teleprompterMode == mode {
            if #available(iOS 26, *) {
                Button { selectMode(mode) } label: { modeSelectorLabel(mode, selected: true) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())
                    .glassEffectUnion(id: "modeSelector", namespace: modeNamespace)
            } else {
                Button { selectMode(mode) } label: { modeSelectorLabel(mode, selected: true) }
                    .buttonStyle(.plain)
                    .background {
                        Capsule()
                            .fill(.primary.opacity(0.15))
                            .matchedGeometryEffect(id: "modeSelectorHighlight", in: modeNamespace)
                    }
            }
        } else {
            Button { selectMode(mode) } label: { modeSelectorLabel(mode, selected: false) }
                .buttonStyle(.plain)
        }
    }
    
    private func modeSelectorLabel(_ mode: TeleprompterMode, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: mode.icon).font(.caption2)
            if selected {
                Text(mode.rawValue)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.85)),
                        removal: .opacity.combined(with: .scale(scale: 0.85))
                    ))
            }
        }
        .font(.caption.bold())
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, selected ? 14 : 10)
        .padding(.vertical, 9)
        .contentShape(Capsule())
    }
    
    private func selectMode(_ mode: TeleprompterMode) {
        guard mode != teleprompterMode else { return }

        switch teleprompterMode {
        case .tap:   viewModel.isTapToAdvance = false
        case .voice: if viewModel.voiceScrollEnabled { Task { await viewModel.toggleVoiceScroll() } }
        case .timed: viewModel.timedDuration = nil
        case .auto:  break
        }

        switch mode {
        case .auto:
            withAnimation(sheetMorphAnimation) { teleprompterMode = .auto }
        case .tap:
            viewModel.isTapToAdvance = true
            withAnimation(sheetMorphAnimation) { teleprompterMode = .tap }
        case .voice:
            guard storeKit.isPremium else { showingPaywall = true; return }
            withAnimation(sheetMorphAnimation) { teleprompterMode = .voice }
            Task { await viewModel.toggleVoiceScroll() }
        case .timed:
            guard storeKit.isPremium else { showingPaywall = true; return }
            let total = TimeInterval(timedMinutes * 60 + timedSeconds)
            viewModel.timedDuration = total > 0 ? total : 180
            withAnimation(sheetMorphAnimation) { teleprompterMode = .timed }
        }
    }

    // MARK: - Background

    private func selectBackground(_ mode: BackgroundMode) {
        guard mode != backgroundMode else { return }
        if backgroundMode == .camera { cameraService.stopCamera() }
        if mode == .camera {
            guard storeKit.isPremium else { showingPaywall = true; return }
            Task { await cameraService.requestPermissionsAndStart() }
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { backgroundMode = mode }
    }
    
    // MARK: - Queue
    
    @ViewBuilder
    private func nextScriptBanner(for next: Script) -> some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Up Next")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(next.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button("Play Now") { advanceToNextScript() }
            }
            
            HStack(spacing: 8) {
                ProgressView(value: Double(5 - nextCountdown), total: 5)
                    .tint(.primary)
                    .animation(.linear(duration: 1), value: nextCountdown)
                
                Text("Auto in \(nextCountdown)s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)
            }
            
            Button("Cancel") { cancelNextBanner() }
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showNextBanner)
    }
    
    private func startNextCountdown() {
        nextCountdown = 5
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for i in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                nextCountdown = i
            }
            guard !Task.isCancelled else { return }
            advanceToNextScript()
        }
    }
    
    private func advanceToNextScript() {
        countdownTask?.cancel()
        withAnimation { showNextBanner = false }
        queueIndex += 1
        liveFontSize = currentScript.customization.fontSize
        lastCrossedCueProgress = -1
        print("[Queue] advanceToNextScript — now at index \(queueIndex): \"\(currentScript.title)\"")
        // Save the stale height before resetting so onHeights can skip it.
        viewModel.pendingAutoPlayStaleHeight = viewModel.contentHeight
        viewModel.prepareForNext(customization: currentScript.customization)
        viewModel.pendingAutoPlay = true
        // Fallback: if the new content has the same height as the old (or onHeights never fires
        // a different value), start after 200 ms — UIKit is always done re-measuring by then.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard viewModel.pendingAutoPlay else { return }
            viewModel.pendingAutoPlay = false
            viewModel.play()
        }
    }
    
    private func cancelNextBanner() {
        countdownTask?.cancel()
        withAnimation { showNextBanner = false }
    }
#endif
    
    // MARK: - Scrolling content
    
    // Shared text body used by both the UIScrollView (iOS) and the fake-scroll (macOS/watchOS)
    private func textBody(textColor: Color? = nil, horizontalPadding: CGFloat = 16) -> some View {
        let displayText = currentScript.content.isEmpty
        ? AttributedString("[ Empty script ]")
        : currentScript.attributedContent
        #if os(iOS)
        let fontSize = liveFontSize
        #else
        let fontSize = customization.fontSize
        #endif
        return Text(displayText)
            .font(.system(size: fontSize))
            .foregroundStyle(textColor ?? Color(hex: customization.textColorHex))
            .multilineTextAlignment(customization.textAlignmentIndex.textAlignment)
            .lineSpacing((customization.lineHeight - 1.0) * fontSize * 0.5)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, alignment: customization.textAlignmentIndex.frameAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(x: customization.isMirrored ? -1 : 1, y: 1)
    }
    
#if !os(iOS)
    // macOS / watchOS: fake-scroll wrapper (offset + geometry tracking)
    private func scrollingContent(screenSize: CGSize, textColor: Color? = nil) -> some View {
        textBody(textColor: textColor)
            .background(
                GeometryReader { contentGeo in
                    Color.clear
                        .preference(key: ContentHeightKey.self, value: contentGeo.size.height)
                        .onAppear { viewModel.contentHeight = contentGeo.size.height }
                }
            )
            .offset(y: -viewModel.contentOffset)
            .onPreferenceChange(ContentHeightKey.self) { viewModel.contentHeight = $0 }
    }
#endif
    
    // MARK: - Voice meter row (macOS)
    
#if !os(watchOS) && !os(iOS)
    private var voiceMeterRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            
            VoiceLevelMeterView(service: viewModel.voiceScrollService)
            
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { viewModel.showVoiceMeter = false }
            } label: {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide level meter")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
        }
    }
#endif
    
    // MARK: - Control bar (macOS + watchOS)
    
#if !os(iOS)
    private var controlBar: some View {
        HStack(spacing: 18) {
            Button { viewModel.resetToTop() } label: {
                Image(systemName: "backward.end.fill").font(.title3)
            }
            .accessibilityLabel("Reset to top")

            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 46))
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

#if !os(watchOS)
            Picker("", selection: Binding(
                get: { macTimedEnabled ? 1 : 0 },
                set: { newVal in
                    if newVal == 1 {
                        guard storeKit.isPremium else { showingPaywall = true; return }
                        macTimedEnabled = true
                        updateMacTimedDuration()
                    } else {
                        macTimedEnabled = false
                        viewModel.timedDuration = nil
                    }
                }
            )) {
                Image(systemName: "hare.fill").tag(0)
                Image(systemName: "timer").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 68)

            if macTimedEnabled {
                if viewModel.isPlaying && viewModel.timedDuration != nil {
                    Text(timeString(viewModel.remainingTime))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .frame(minWidth: 60)
                } else {
                    HStack(spacing: 4) {
                        Button {
                            if macTimedMinutes > 0 { macTimedMinutes -= 1; updateMacTimedDuration() }
                        } label: {
                            Image(systemName: "minus").font(.caption2)
                        }
                        Text("\(macTimedMinutes)m")
                            .font(.caption.monospacedDigit().bold())
                            .frame(minWidth: 28)
                        Button {
                            macTimedMinutes = min(59, macTimedMinutes + 1)
                            updateMacTimedDuration()
                        } label: {
                            Image(systemName: "plus").font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            } else {
                MusicSlider(
                    value: $viewModel.scrollSpeed,
                    range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                    step: 0.1
                )

                Text(String(format: "%.1fx", viewModel.scrollSpeed))
                    .font(.caption.bold().monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
#else
            MusicSlider(
                value: $viewModel.scrollSpeed,
                range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                step: 0.1
            )

            Text(String(format: "%.1fx", viewModel.scrollSpeed))
                .font(.caption.bold().monospacedDigit())
                .frame(width: 40, alignment: .trailing)
#endif

            Toggle(isOn: $viewModel.isTapToAdvance) {
                Image(systemName: "hand.tap.fill").font(.footnote)
            }
            .toggleStyle(.button)
            .tint(.white.opacity(0.3))
            .accessibilityLabel("Tap to advance")

#if !os(watchOS)
            Button {
                if storeKit.isPremium {
                    Task { await viewModel.toggleVoiceScroll() }
                } else {
                    showingPaywall = true
                }
            } label: {
                Image(systemName: viewModel.voiceScrollEnabled ? "mic.fill" : "mic")
                    .font(.footnote)
                    .foregroundStyle(viewModel.voiceScrollEnabled ? Color.green : Color.white)
            }
            .accessibilityLabel(viewModel.voiceScrollEnabled ? "Disable Voice Scroll" : "Enable Voice Scroll")

            if viewModel.voiceScrollEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { viewModel.showVoiceMeter.toggle() }
                } label: {
                    Image(systemName: viewModel.showVoiceMeter ? "waveform" : "waveform.slash")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(viewModel.showVoiceMeter ? 1.0 : 0.5))
                }
                .accessibilityLabel(viewModel.showVoiceMeter ? "Hide level meter" : "Show level meter")
            }
#endif
        }
        .tint(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
        }
    }
#endif
    
    // MARK: - Helpers

    private func saveLastProgress() {
        let p = viewModel.progress
        guard p > 0 else { return }
        currentScript.lastProgress = p
        try? modelContext.save()
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

#if !os(watchOS) && !os(iOS)
    private func updateMacTimedDuration() {
        let total = TimeInterval(macTimedMinutes * 60)
        viewModel.timedDuration = total > 0 ? total : 180
    }
#endif

#if !os(watchOS)
    private func openMicSettings() {
#if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
#elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
#endif
    }
#endif
}

// MARK: - UIScrollView-backed teleprompter (iOS)

#if os(iOS)
private final class _ScrollContainer: UIScrollView {
    var onLayout: ((CGFloat, CGFloat) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        let visibleHeight = bounds.height - adjustedContentInset.top
        guard contentSize.height > 0, visibleHeight > 0 else { return }
        onLayout?(contentSize.height, visibleHeight)
    }
}

private struct TeleprompterScrollView<Content: View>: UIViewRepresentable {
    @Binding var offset: CGFloat
    let content: Content
    let onHeights: (CGFloat, CGFloat) -> Void
    var bottomInset: CGFloat = 0
    var scriptID: UUID? = nil
    var fontSize: CGFloat = 0
    var horizontalPadding: CGFloat = 0

    final class Coordinator {
        var hosting: UIHostingController<Content>?
        var lastScriptID: UUID? = nil
        var lastFontSize: CGFloat = 0
        var lastHorizontalPadding: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> _ScrollContainer {
        let sv = _ScrollContainer()
        sv.isScrollEnabled = false
        sv.showsVerticalScrollIndicator = false
        sv.backgroundColor = .clear
        sv.contentInsetAdjustmentBehavior = .always
        // contentInset.bottom must be >= bottomInset + 80 so the UIScrollView can reach
        // the ViewModel's maxOffset (contentHeight - visibleHeight + 80).
        sv.contentInset.bottom = bottomInset + 80
        sv.onLayout = onHeights

        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: sv.frameLayoutGuide.widthAnchor),
        ])
        context.coordinator.hosting = host
        context.coordinator.lastScriptID = scriptID
        return sv
    }

    func updateUIView(_ sv: _ScrollContainer, context: Context) {
        sv.onLayout = onHeights
        let needed = bottomInset + 80
        if sv.contentInset.bottom != needed {
            sv.contentInset.bottom = needed
            sv.setNeedsLayout()
        }
        context.coordinator.hosting?.rootView = content

        // UIHostingController does not automatically invalidate its intrinsic content size
        // when rootView changes, so contentSize can stay stale after a script switch or when
        // font size / margins change. Force a synchronous re-measure whenever any of those
        // content-shaping parameters change.
        let needsRelayout = scriptID != context.coordinator.lastScriptID
            || fontSize != context.coordinator.lastFontSize
            || horizontalPadding != context.coordinator.lastHorizontalPadding
        if needsRelayout {
            context.coordinator.lastScriptID = scriptID
            context.coordinator.lastFontSize = fontSize
            context.coordinator.lastHorizontalPadding = horizontalPadding
            context.coordinator.hosting?.view.invalidateIntrinsicContentSize()
            context.coordinator.hosting?.view.setNeedsLayout()
            sv.layoutIfNeeded()   // updates contentSize + fires onLayout before offset write below
        }

        let insetTop = sv.adjustedContentInset.top
        let target = CGPoint(x: 0, y: offset - insetTop)
        guard sv.contentOffset != target else { return }
        // Large jumps (seek / reset / cue) get a UIKit ease-out; frame-by-frame auto-scroll is direct.
        if abs(sv.contentOffset.y - target.y) > 20 {
            UIView.animate(withDuration: 0.35, delay: 0,
                           options: [.curveEaseOut, .beginFromCurrentState]) {
                sv.contentOffset = target
            }
        } else {
            sv.contentOffset = target
        }
    }
}
#endif

#if os(iOS)
private struct CameraPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession
    // Passed so updateUIView is triggered on device rotation.
    let verticalSizeClass: UserInterfaceSizeClass?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.applyCurrentOrientation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyCurrentOrientation()
        }

        func applyCurrentOrientation() {
            guard let connection = previewLayer.connection else { return }
            let orientation: UIInterfaceOrientation
            if #available(iOS 26.0, *) {
                orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            } else {
                orientation = window?.windowScene?.interfaceOrientation ?? .portrait
            }
            if #available(iOS 17.0, *) {
                let angle: CGFloat
                switch orientation {
                // Front camera mirror swaps landscape directions
                case .landscapeLeft:      angle = 0
                case .landscapeRight:     angle = 180
                case .portraitUpsideDown: angle = 270
                default:                  angle = 90
                }
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            } else {
                let avOrientation: AVCaptureVideoOrientation
                switch orientation {
                // Front camera mirror swaps landscape directions
                case .landscapeLeft:      avOrientation = .landscapeRight
                case .landscapeRight:     avOrientation = .landscapeLeft
                case .portraitUpsideDown: avOrientation = .portraitUpsideDown
                default:                  avOrientation = .portrait
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = avOrientation
                }
            }
        }
    }
}
#endif

