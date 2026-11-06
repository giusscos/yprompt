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
private enum BackgroundMode: Hashable {
    case solidColor
    case camera
}

private enum CameraLayout: Hashable {
    /// A few lines right under the Dynamic Island or notch, over an unobstructed preview.
    case underCamera
    case fullScreen
    case split
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AppStorage("splitCameraLayout") private var isSplitCamera = false
    @AppStorage("splitCameraPromptOnLeading") private var promptOnLeading = false
    @AppStorage("cameraUnderLens") private var prefersUnderCamera = true
    @State private var safeTopInset: CGFloat = 0
    @State private var safeBottomInset: CGFloat = 0
    @State private var safeLeadingInset: CGFloat = 0
    @State private var safeTrailingInset: CGFloat = 0
    @State private var stopCameraTask: Task<Void, Never>?
    @State private var layoutFrame: CGRect = .zero
    @State private var liveHorizontalPadding: CGFloat = 16
    @AppStorage(ReadingPreferences.modeKey) private var savedMode = TeleprompterMode.auto.rawValue
    @AppStorage(ReadingPreferences.backgroundKey) private var savedBackground = ReadingPreferences.colorBackground
    @AppStorage(ReadingPreferences.marginsKey) private var savedMargins: Double = 16
    @AppStorage(ReadingPreferences.timedSecondsKey) private var savedTimedSeconds = 180
    @State private var teleprompterMode: TeleprompterMode = .auto
    @State private var backgroundMode: BackgroundMode = .solidColor
    #if DEBUG
    @AppStorage(AppConstants.debugDemoCameraKey) private var useDemoCameraBackground = false
    #endif
    @State private var showNextBanner = false
    @State private var nextCountdown = 5
    @State private var countdownTask: Task<Void, Never>? = nil
    @State private var timedMinutes: Int = 3
    @State private var timedSeconds: Int = 0
    @State private var classicScrubStart: CGFloat?
    @State private var liveFontSize: CGFloat = AppConstants.defaultFontSize
    @State private var lastCrossedCueProgress: Double = -1
    @State private var showDisplayAdjustments = false
    @State private var showCameraSettings = false
    @State private var isExitingPlayMode = false
    @State private var didRestoreTabBar = false
    @State private var didRestoreProgress = false
    /// Reading position held while the text rewraps to a new width (rotation, Split View,
    /// or folding/unfolding iPhone Duo), so the reader stays on the same line.
    @State private var reflowProgress: Double? = nil
    @State private var reflowStaleHeight: CGFloat = 0
#endif
#if !os(watchOS)
    @AppStorage("sliderRequiresLongPress") private var sliderRequiresLongPress: Bool = true
    @AppStorage(AppConstants.lyricsStyleKey) private var lyricsStyleEnabled: Bool = true
    @State private var paywallContext: PaywallView.Context = .upgrade
#endif
#if !os(watchOS) && !os(iOS)
    @State private var macTimedEnabled = false
    @State private var macTimedMinutes: Int = 3
    @State private var didRestoreProgress = false
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
    /// Lyrics style is Pro. Voice needs it to show the word being read, the under-camera
    /// layout is built around it, and the sample script lets everyone try it.
    private var usesWordStyle: Bool {
        guard let words = viewModel.scriptWords, !words.isEmpty, !words.isRightToLeft else { return false }
        if teleprompterMode == .voice || isUnderCamera { return true }
        return lyricsStyleEnabled && (storeKit.isPremium || currentScript.id == AppConstants.welcomeScriptID)
    }

    private var isBackgroundDark: Bool {
        if cameraBehindText || isUnderCamera { return true }
        let uiColor = UIColor(Color(hex: customization.backgroundColorHex))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        return 0.299 * r + 0.587 * g + 0.114 * b < 0.5
    }

    private var controlsAnimation: Animation { .spring(response: 0.38, dampingFraction: 0.86) }
    /// Changing background or layout: everything moves together, without a bounce.
    private var surfaceAnimation: Animation { .easeInOut(duration: 0.45) }
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
    
    // MARK: - iOS Body

#if os(iOS)
    /// Debug builds: camera mode shows the bundled demo photo instead of the live camera.
    private var usesDemoCamera: Bool {
        #if DEBUG
        return useDemoCameraBackground
        #else
        return false
        #endif
    }

    /// The image fades in once there is something to show, so the live camera never appears as a black flash.
    private var isCameraFeedVisible: Bool {
        backgroundMode == .camera && (usesDemoCamera || cameraService.isPreviewRunning)
    }

    /// Split needs room for two usable halves: the unfolded iPhone Duo, or an iPad.
    private var canSplitCamera: Bool { horizontalSizeClass == .regular }

    /// Camera preview in one half, prompt in the other. Side by side on wide layouts,
    /// prompt on top (nearest the front camera) on tall ones.
    private var splitAxis: Axis? {
        guard isSplitCamera, canSplitCamera, backgroundMode == .camera,
              layoutSize.width > 0 else { return nil }
        return layoutSize.width >= layoutSize.height ? .horizontal : .vertical
    }

    private var cameraBehindText: Bool { backgroundMode == .camera && splitAxis == nil }

    private var cameraLayout: CameraLayout {
        get {
            if isSplitCamera && canSplitCamera { return .split }
            return prefersUnderCamera ? .underCamera : .fullScreen
        }
        nonmutating set {
            isSplitCamera = newValue == .split
            if newValue != .split { prefersUnderCamera = newValue == .underCamera }
        }
    }

    private var isUnderCamera: Bool {
        backgroundMode == .camera && cameraLayout == .underCamera
    }

    private var layoutSize: CGSize { layoutFrame.size }

    /// Side-by-side camera pane: half the width.
    private var cameraPaneWidth: CGFloat { layoutSize.width / 2 }

    /// Stacked camera pane: half the height, down to the very bottom of the screen.
    private var cameraPaneHeight: CGFloat { layoutSize.height / 2 + safeBottomInset }

    /// In split mode the controls float over the camera half, off the prompt.
    private var dockCoversPrompt: Bool { splitAxis == nil }

    /// Where the script starts, right under the toolbar.
    private var readingTopInset: CGFloat { safeTopInset }

    /// Fixed, whether or not the controls are showing, so the text never jumps when they fade.
    private var readingBottomInset: CGFloat {
        guard dockCoversPrompt else { return 0 }
        return verticalSizeClass == .compact ? 84 : 190
    }

    /// Live camera feed, or the bundled demo photo in debug builds.
    @ViewBuilder
    private var cameraFeed: some View {
        if usesDemoCamera {
            // In an overlay, so a photo of another shape can't make the background overflow the screen.
            Color.clear.overlay {
                Image("CameraDemoBackground")
                    .resizable()
                    .scaledToFill()
            }
        } else if let session = cameraService.captureSession {
            CameraPreviewRepresentable(session: session, camera: cameraService)
        }
    }

    /// One set of layers for every background and layout, so changing between them is a
    /// fade and the camera preview is never rebuilt.
    private var readingBackground: some View {
        let axis = splitAxis
        let alignment: Alignment = switch axis {
        case .horizontal: promptOnLeading ? .trailing : .leading
        case .vertical: .bottom
        case nil: .center
        }
        return ZStack(alignment: alignment) {
            Color.black
            Color(hex: customization.backgroundColorHex)
                .opacity(backgroundMode == .solidColor || axis != nil ? 1 : 0)
            cameraFeed
                .frame(
                    // Out to the screen edge on its own side only.
                    width: axis == .horizontal ? cameraPaneWidth + (promptOnLeading ? safeTrailingInset : safeLeadingInset) : nil,
                    height: axis == .vertical ? cameraPaneHeight : nil
                )
                .frame(
                    maxWidth: axis == .horizontal ? nil : .infinity,
                    maxHeight: axis == .vertical ? nil : .infinity
                )
                .clipped()
                .opacity(isCameraFeedVisible ? 1 : 0)
                .animation(.easeIn(duration: 0.35), value: isCameraFeedVisible)
            Color.black.opacity(cameraBehindText && !isUnderCamera ? 0.42 : 0)
        }
        .overlay(alignment: .top) { underCameraShade }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// How far down the text stays visible: the whole screen, or a few lines under the camera.
    private var readingMask: some View {
        let fadeHeight = isUnderCamera ? underCameraBandHeight * 0.32 : 40
        let solidHeight: CGFloat
        if isUnderCamera {
            solidHeight = underCameraBandHeight * 0.62 + 8
        } else if cameraBehindText {
            // The controls' shade is see-through over the camera, so the text has to stop above them.
            solidHeight = max(0, layoutSize.height + safeTopInset + safeBottomInset - readingBottomInset - readingTopInset - fadeHeight - 20)
        } else {
            solidHeight = layoutSize.height + safeTopInset + safeBottomInset
        }
        return VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.55),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(readingTopInset + 2, 18))
            Color.black.frame(height: solidHeight)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: fadeHeight)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The same text view in every word-style layout: changing layout restyles it in place.
    private var readingSurface: some View {
        ZStack {
            if viewModel.isWordMode, let words = viewModel.scriptWords {
                AnimatedWordSurface(
                    viewModel: viewModel,
                    words: words,
                    fontSize: liveFontSize,
                    lineHeightMultiple: customization.lineHeight,
                    promptColor: Color(hex: customization.textColorHex),
                    alignment: customization.textAlignmentIndex,
                    horizontalPadding: liveHorizontalPadding,
                    topInset: readingTopInset + 8,
                    bottomInset: readingBottomInset,
                    isMirrored: customization.isMirrored,
                    onScrub: handleScrub,
                    cameraAmount: cameraBehindText ? 1 : 0,
                    underCameraAmount: isUnderCamera ? 1 : 0
                )
                .transition(.opacity)
            } else {
                classicScrollView
                    .contentShape(Rectangle())
                    .gesture(classicScrubGesture)
                    .transition(.opacity)
            }
        }
        // Top-aligned: over a color the mask runs past the bottom of the screen.
        .mask(alignment: .top) { readingMask }
        .animation(.easeInOut(duration: 0.3), value: viewModel.isWordMode)
    }

    private var classicScrollView: some View {
        TeleprompterScrollView(
            offset: $viewModel.contentOffset,
            content: textBody(textColor: cameraBehindText ? .white : nil, horizontalPadding: liveHorizontalPadding, topInset: max(0, readingTopInset - 16)),
            onHeights: { contentHeight, screenHeight, widthChanged in
                print("[Queue] onHeights — contentHeight=\(Int(contentHeight)) screenHeight=\(Int(screenHeight))")
                if widthChanged && didRestoreProgress && !viewModel.pendingAutoPlay && viewModel.contentHeight > 0 {
                    // Capture progress with the old heights before they're overwritten.
                    reflowProgress = viewModel.progress
                    reflowStaleHeight = viewModel.contentHeight
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        reflowProgress = nil
                    }
                }
                viewModel.contentHeight = contentHeight
                // Subtract the controls' space so maxOffset reflects only the readable area above them.
                viewModel.screenHeight = max(100, screenHeight - readingBottomInset)
                // SwiftUI re-measures the rewrapped text a pass after the width changes;
                // re-anchor until the new height lands.
                if let p = reflowProgress {
                    viewModel.contentOffset = max(0, viewModel.contentHeight - viewModel.screenHeight + 80) * CGFloat(p)
                    if contentHeight != reflowStaleHeight { reflowProgress = nil }
                }
                // Restore saved scroll position once layout is ready (only on first load, not queue advances).
                if !didRestoreProgress && contentHeight > 0 {
                    didRestoreProgress = true
                    let p = currentScript.lastProgress
                    if p > 0 && p < 1 { viewModel.seek(to: p) }
                }
                viewModel.restoreClassicPositionIfNeeded()
                // After a queue advance, UIKit fires one stale layout with the old script's height
                // before the new content is measured. Only start playing once a different (real)
                // height arrives — the 200 ms Task in advanceToNextScript handles the same-height edge case.
                if viewModel.pendingAutoPlay && contentHeight > 0 && contentHeight != viewModel.pendingAutoPlayStaleHeight {
                    viewModel.pendingAutoPlay = false
                    viewModel.play()
                }
            },
            bottomInset: readingBottomInset,
            scriptID: currentScript.id,
            fontSize: liveFontSize,
            horizontalPadding: liveHorizontalPadding,
            topInset: readingTopInset
        )
    }

    private var iOSBody: some View {
        readingSurface
        .padding(.leading, splitAxis == .horizontal && !promptOnLeading ? cameraPaneWidth : 0)
        .padding(.trailing, splitAxis == .horizontal && promptOnLeading ? cameraPaneWidth : 0)
        .padding(.bottom, splitAxis == .vertical ? cameraPaneHeight : 0)
        // Vertical only: side insets (landscape notch, iPhone Duo's camera/toolbar rail when folded)
        // must stay clear or the ends of lines get covered.
        .ignoresSafeArea(edges: .vertical)
        .background { readingBackground }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layoutFrame = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { inset in
            // Hiding the toolbar shrinks the safe area; keep its space so the text doesn't jump.
            safeTopInset = controlsVisible ? inset : max(safeTopInset, inset)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottomInset = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { safeLeadingInset = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: { safeTrailingInset = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: handleSurfaceTap)
        .overlay(alignment: .bottom) { bottomControls }
        .onAppear {
            viewModel.transparency = customization.transparency
            applyReadingPreferences()
            if viewModel.scriptWords == nil {
                viewModel.load(words: currentScript.scriptWords)
            }
            restoreModeAndBackground()
            Task { await offerUnsavedTake() }
            viewModel.setWordMode(usesWordStyle)
            if viewModel.isWordMode && !didRestoreProgress {
                didRestoreProgress = true
                var p = currentScript.lastProgress
                #if DEBUG
                // For App Store screenshots: launch with `-ypShotProgress 0.2`.
                let shot = UserDefaults.standard.double(forKey: "ypShotProgress")
                if shot > 0 { p = shot }
                #endif
                if p > 0 && p < 1 { viewModel.seek(to: p) }
            }
        }
        .onChange(of: usesWordStyle) { _, usesWords in viewModel.setWordMode(usesWords) }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .background(NavigationInteractivePopGestureDisabler(disabled: true))
        .toolbarColorScheme(isBackgroundDark ? .dark : .light, for: .navigationBar)
        .toolbar { iOSToolbar }
        .toolbar(controlsVisible ? .visible : .hidden, for: .navigationBar)
        .onChange(of: verticalSizeClass) {
            // Rotating changes the toolbar's height, so show it to measure the new space.
            if viewModel.isPlaying { viewModel.showControlsTemporarily() }
        }
        // Also gives the tab bar's space back: the animator only slides it out of sight.
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(true)
        .opacity(viewModel.transparency)
        .overlay(alignment: .top) {
            // Floats under the toolbar, so nothing on screen moves when it appears.
            if showNextBanner, let next = nextQueueScript {
                nextScriptBanner(for: next)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(context: paywallContext).environment(storeKit)
        }
        .onChange(of: showingPaywall) { _, showing in
            if !showing { paywallContext = .upgrade }
        }
        .onChange(of: cameraService.isCameraActive) { _, active in
            viewModel.voiceScrollService.sharesAudioSessionWithCamera = active
        }
        .alert("Microphone Access Required", isPresented: $viewModel.micPermissionDenied) {
            Button("Open Settings") { openMicSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Voice Scroll needs microphone access to detect when you are speaking.")
        }
        .onChange(of: viewModel.micPermissionDenied) { _, denied in
            if denied {
                savedMode = TeleprompterMode.auto.rawValue
                withAnimation(controlsAnimation) { teleprompterMode = .auto }
            }
        }
        .alert("Camera & Microphone Access Required", isPresented: $cameraService.permissionDenied) {
            Button("Open Settings") { openMicSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Camera mode needs camera and microphone access to record video.")
        }
        .fullScreenCover(item: $cameraService.finishedTake) { take in
            let script = queueScripts.first { $0.id == take.scriptID } ?? currentScript
            TakeReviewView(
                take: take,
                script: script.scriptWords,
                title: script.title,
                onRetake: {
                    viewModel.seek(to: take.startProgress)
                    cameraService.finishedTake = nil
                },
                onFinish: { cameraService.finishedTake = nil }
            )
            .environment(storeKit)
        }
        .onChange(of: cameraService.finishedTake) { _, take in
            // The camera keeps running underneath, so Retake can start again straight away.
            if take != nil { viewModel.pause() }
        }
        .onChange(of: keepsScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onChange(of: cameraService.permissionDenied) { _, denied in
            if denied {
                savedBackground = ReadingPreferences.colorBackground
                withAnimation { backgroundMode = .solidColor }
            }
        }
        .onChange(of: viewModel.isFinished) { _, finished in
            guard finished else { return }
            currentScript.lastProgress = 1.0
            try? modelContext.save()
            RatingService.shared.recordSessionCompleted()
            if nextQueueScript != nil {
                showNextBanner = true
                startNextCountdown()
            } else if !storeKit.isPremium && RatingService.shared.claimFirstReadPaywall() {
                paywallContext = .firstRead
                showingPaywall = true
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

    // MARK: - Toolbar

    /// Back and settings, in the system's own positions on every device.
    @ToolbarContentBuilder
    private var iOSToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: exitPlayMode) {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Go Back")
            // A take can't be left by accident.
            .disabled(isExitingPlayMode || cameraService.isRecording)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                backgroundMenuItems
                    // Hiding the toolbar would close the menu. iOS doesn't report the menu
                    // closing, so this is a long delay rather than a hold until it does.
                    .onAppear { if viewModel.isPlaying { viewModel.showControlsTemporarily(for: 15) } }
            } label: {
                Image(systemName: backgroundMode == .camera ? "camera.fill" : "paintpalette.fill")
            }
            .accessibilityLabel("Background")
            .background {
                // Separate anchor: a menu can't host the popover it opens.
                Color.clear
                    .popover(isPresented: $showCameraSettings, arrowEdge: .top) {
                        ScrollView {
                            CameraSettingsView(camera: cameraService).padding()
                        }
                        .frame(idealHeight: 460)
                        .presentationCompactAdaptation(.popover)
                    }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showDisplayAdjustments.toggle()
            } label: {
                Image(systemName: "textformat.size")
            }
            .accessibilityLabel("Display adjustments")
            .popover(isPresented: $showDisplayAdjustments, arrowEdge: .top) {
                displayAdjustmentsPopover
                    .padding()
                    .frame(minWidth: 280)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder
    private var backgroundMenuItems: some View {
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
            Label("Camera", systemImage: storeKit.isPremium ? "camera.fill" : "lock.fill")
            if backgroundMode == .camera {
                Image(systemName: "checkmark")
            }
        }
        if backgroundMode == .camera {
            Divider()
            Picker("Layout", selection: Binding(
                get: { cameraLayout },
                set: { newLayout in withAnimation(surfaceAnimation) { cameraLayout = newLayout } }
            )) {
                Label("Under the Camera", systemImage: "rectangle.topthird.inset.filled").tag(CameraLayout.underCamera)
                Label("Full Screen", systemImage: "text.below.photo").tag(CameraLayout.fullScreen)
                if canSplitCamera {
                    Label("Split Screen", systemImage: "rectangle.split.2x1").tag(CameraLayout.split)
                }
            }
            .pickerStyle(.inline)
            if cameraLayout == .split {
                Button {
                    withAnimation(surfaceAnimation) { promptOnLeading.toggle() }
                } label: {
                    Label("Swap Sides", systemImage: "arrow.left.arrow.right")
                }
            }
            Divider()
            if cameraService.canSwitchCamera {
                Button {
                    cameraService.switchCamera()
                } label: {
                    Label(
                        cameraService.cameraPosition == .front ? "Use Back Camera" : "Use Front Camera",
                        systemImage: "arrow.triangle.2.circlepath.camera"
                    )
                }
                .disabled(cameraService.isRecording)
            }
            if cameraService.isCameraActive {
                Button {
                    showCameraSettings = true
                } label: {
                    Label("Camera Settings…", systemImage: "camera.aperture")
                }
            }
        }
    }

    // MARK: - Under-camera layout

    /// Lines shown in the band under the camera.
    private var underCameraBandHeight: CGFloat {
        let lineHeight = liveFontSize * 1.2 + (customization.lineHeight - 1.0) * liveFontSize * 0.5 + liveFontSize * 0.12
        return lineHeight * 3
    }

    /// Keeps the lines under the camera readable over a bright preview.
    private var underCameraShade: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.92), location: 0),
                .init(color: .black.opacity(0.78), location: 0.6),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: readingTopInset + underCameraBandHeight + 44)
        .opacity(isUnderCamera ? 1 : 0)
    }

    private func recordingTime(since start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { timeline in
            let total = max(0, Int(timeline.date.timeIntervalSince(start)))
            Text(String(format: "%02d:%02d", total / 60, total % 60))
        }
    }

    /// One button for the take: recording and reading start and stop together.
    private func toggleRecording() {
        let starting = !cameraService.isRecording
        cameraService.toggleRecording(scriptID: currentScript.id, startProgress: viewModel.progress)
        guard teleprompterMode != .tap else { return }
        if starting {
            viewModel.play()
        } else {
            viewModel.pause()
        }
    }

    // MARK: - Bottom controls

    /// Reading comes first: while the script plays the controls get out of the way.
    private var controlsVisible: Bool {
        viewModel.showControls || !viewModel.isPlaying || viewModel.isScrubbing
            || showDisplayAdjustments || showCameraSettings
            || teleprompterMode == .tap || voiceOverEnabled
    }

    /// Over the camera, or anywhere dark, the controls are light on dark.
    private var controlsAreDark: Bool { splitAxis != nil || isBackgroundDark }

    private var bottomControls: some View {
        ZStack(alignment: .bottom) {
            bottomScrim
            progressLineFade
            VStack(spacing: 10) {
                dock
                    .opacity(controlsVisible ? 1 : 0)
                    .offset(y: controlsVisible ? 0 : 10)
                    .allowsHitTesting(controlsVisible)
                ReadingProgressLine(
                    progress: viewModel.progress,
                    cuePositions: currentScript.cuePoints.map(\.position)
                )
                .padding(.horizontal, 28)
                .opacity(controlsVisible ? 1 : 0.5)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: splitAxis == .horizontal ? cameraPaneWidth : .infinity)
            .frame(maxWidth: .infinity, alignment: dockAlignment)
        }
        .environment(\.colorScheme, controlsAreDark ? .dark : .light)
        .tint(.primary)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(controlsAnimation, value: teleprompterMode)
    }

    private var dockAlignment: Alignment {
        guard splitAxis == .horizontal else { return .center }
        return promptOnLeading ? .trailing : .leading
    }

    /// Lets the text fade out behind the controls, and lifts them off a busy camera image.
    private var bottomScrim: some View {
        let color = backgroundMode == .camera ? Color.black.opacity(0.55) : Color(hex: customization.backgroundColorHex)
        // In a full-height stack, so it reaches the very bottom of the screen.
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: color.opacity(0), location: 0),
                    .init(color: color, location: 0.2),
                    .init(color: color, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: readingBottomInset + 100)
        }
        .opacity(controlsVisible && readingBottomInset > 0 ? 1 : 0)
        .ignoresSafeArea(edges: [.bottom, .horizontal])
        .allowsHitTesting(false)
    }

    /// While reading with the controls hidden, text still fades out before the progress line.
    private var progressLineFade: some View {
        let color = Color(hex: customization.backgroundColorHex)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: color.opacity(0), location: 0),
                    .init(color: color, location: 0.5),
                    .init(color: color, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 96)
        }
        .ignoresSafeArea(edges: [.bottom, .horizontal])
        .opacity(backgroundMode == .solidColor && readingBottomInset > 0 ? 1 : 0)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var dock: some View {
        if verticalSizeClass == .compact {
            HStack(spacing: 14) {
                leadingTransportButton
                primaryTransportButton(size: 54)
                trailingTransportButton
                modeStrip.frame(maxWidth: 300)
                modeAccessory.frame(minWidth: 130)
                recordingBadge
            }
            .padding(.horizontal, 16)
        } else {
            VStack(spacing: 12) {
                modeAccessory
                    .frame(minHeight: 34)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) { recordingBadge.padding(.leading, 6) }
                modeStrip
                HStack {
                    leadingTransportButton
                    Spacer(minLength: 0)
                    primaryTransportButton(size: 68)
                    Spacer(minLength: 0)
                    trailingTransportButton
                }
                .padding(.horizontal, 22)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 16)
        }
    }

    /// How long the take has been running.
    @ViewBuilder
    private var recordingBadge: some View {
        if cameraService.isRecording, let start = cameraService.recordingStartDate {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7)
                recordingTime(since: start)
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 34)
            .ypGlassEffect(cornerRadius: 17)
            .transition(.opacity)
        }
    }

    private var modeStrip: some View {
        ReadingModeStrip(
            selection: teleprompterMode,
            highlight: controlsAreDark ? .yellow : .accentColor,
            isLocked: { !storeKit.isPremium && ($0 == .voice || $0 == .timed) },
            onSelect: selectMode
        )
    }

    /// The one setting that matters for the current mode.
    @ViewBuilder
    private var modeAccessory: some View {
        if viewModel.isScrubbing {
            Text(String(format: "%d%%", Int(viewModel.progress * 100)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .padding(.horizontal, 16)
                .frame(height: 34)
                .ypGlassEffect(cornerRadius: 17)
        } else {
            switch teleprompterMode {
            case .auto:
                ReadingValueStepper(
                    value: String(format: "%.1f×", viewModel.scrollSpeed),
                    onDecrease: { stepSpeed(by: -0.1) },
                    onIncrease: { stepSpeed(by: 0.1) }
                )
                .transition(.blurReplace)
            case .tap:
                Text("Tap the script to advance")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.blurReplace)
            case .voice:
                voiceAccessory
                    .transition(.blurReplace)
            case .timed:
                timedAccessory
                    .transition(.blurReplace)
            }
        }
    }

    @ViewBuilder
    private var voiceAccessory: some View {
        let service = viewModel.voiceScrollService
        if !service.isRunning {
            Text("Press play and start reading")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if service.isTrackingWords {
            HStack(spacing: 8) {
                VoiceLevelBars(service: service)
                (service.isSpeaking ? Text("Following your words") : Text("Listening for your voice..."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .animation(nil, value: service.isSpeaking)
            }
        } else {
            // Without speech recognition, loudness moves the script, so the level can be tuned.
            VoiceLevelMeterView(service: service, showStatus: true)
                .padding(.horizontal, 22)
        }
    }

    @ViewBuilder
    private var timedAccessory: some View {
        if viewModel.isPlaying {
            Text("\(timeString(viewModel.remainingTime)) left")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.default, value: viewModel.remainingTime)
        } else {
            ReadingValueStepper(
                value: timedDurationString,
                onDecrease: { stepTimedDuration(by: -30) },
                onIncrease: { stepTimedDuration(by: 30) }
            )
        }
    }

    private func stepSpeed(by amount: Double) {
        let stepped = ((viewModel.scrollSpeed + amount) * 10).rounded() / 10
        viewModel.scrollSpeed = min(AppConstants.maxScrollSpeed, max(AppConstants.minScrollSpeed, stepped))
        ReadingPreferences.speed = viewModel.scrollSpeed
        if viewModel.isPlaying { viewModel.showControlsTemporarily() }
    }

    // MARK: - Transport

    private var leadingTransportButton: some View {
        Button { viewModel.resetToTop() } label: {
            transportIcon("arrow.counterclockwise")
        }
        .buttonStyle(.plain)
        .ypGlassEffect(cornerRadius: 23)
        .accessibilityLabel("Reset to top")
    }

    /// Play, or advance in tap mode. In camera mode the big button records, as in the Camera app.
    @ViewBuilder
    private func primaryTransportButton(size: CGFloat) -> some View {
        if backgroundMode == .camera {
            recordButton(size: size)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else {
            Button(action: readingAction) {
                Image(systemName: readingActionIcon)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(controlsAreDark ? Color.black : Color.white)
                    .frame(width: size, height: size)
                    .background(controlsAreDark ? Color.white : Color.black, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: viewModel.isPlaying)
            .accessibilityLabel(readingActionLabel)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    private func recordButton(size: CGFloat) -> some View {
        let isRecording = cameraService.isRecording
        return Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 3.5)
                RoundedRectangle(cornerRadius: isRecording ? 7 : size / 2)
                    .fill(.red)
                    .frame(width: isRecording ? size * 0.4 : size - 12, height: isRecording ? size * 0.4 : size - 12)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isRecording)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
    }

    /// Next to the record button: play or advance. Otherwise: cue points.
    @ViewBuilder
    private var trailingTransportButton: some View {
        if backgroundMode == .camera {
            Button(action: readingAction) {
                transportIcon(readingActionIcon)
            }
            .buttonStyle(.plain)
            .ypGlassEffect(cornerRadius: 23)
            .accessibilityLabel(readingActionLabel)
        } else {
            cueMenu
        }
    }

    private var readingActionIcon: String {
        if teleprompterMode == .tap { return "arrow.down" }
        return viewModel.isPlaying ? "pause.fill" : "play.fill"
    }

    private var readingActionLabel: LocalizedStringKey {
        if teleprompterMode == .tap { return "Advance" }
        return viewModel.isPlaying ? "Pause" : "Play"
    }

    private func readingAction() {
        if teleprompterMode == .tap {
            viewModel.tapAdvance()
        } else {
            viewModel.togglePlayPause()
        }
    }

    private func transportIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 46, height: 46)
            .contentShape(Circle())
    }

    /// Tap to mark the current place; press and hold to jump to a mark or clear them.
    private var cueMenu: some View {
        Menu {
            ForEach(Array(currentScript.cuePoints.enumerated()), id: \.element.id) { index, cue in
                Button {
                    viewModel.jumpToCue(cue)
                } label: {
                    Label("Cue \(index + 1)", systemImage: "flag")
                    Text(String(format: "%d%%", Int(cue.position * 100)))
                }
            }
            if !currentScript.cuePoints.isEmpty {
                Divider()
                Button(role: .destructive) {
                    performResetCuePoints()
                } label: {
                    Label("Reset Cue Points", systemImage: "flag.slash.fill")
                }
            }
        } label: {
            transportIcon("flag.fill")
        } primaryAction: {
            addCueAtCurrentPosition()
        }
        .buttonStyle(.plain)
        .ypGlassEffect(cornerRadius: 23)
        .opacity(viewModel.progress > 0 ? 1 : 0.4)
        .sensoryFeedback(.impact(weight: .light), trigger: currentScript.cuePoints.count)
        .accessibilityLabel("Add Cue Point")
    }

    // MARK: - Touching the script

    private func handleSurfaceTap() {
        if viewModel.isTapToAdvance {
            viewModel.tapAdvance()
        } else {
            viewModel.toggleControls()
        }
    }

    /// The script is its own scrubber: drag it to move through it.
    private func handleScrub(_ isScrubbing: Bool) {
        if isScrubbing {
            viewModel.beginScrub()
        } else {
            viewModel.endScrub()
        }
    }

    private var classicScrubGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if classicScrubStart == nil {
                    classicScrubStart = viewModel.contentOffset
                    viewModel.beginScrub()
                }
                viewModel.scrubClassic(to: (classicScrubStart ?? 0) - value.translation.height)
            }
            .onEnded { _ in
                classicScrubStart = nil
                viewModel.endScrub()
            }
    }

    /// A take that was never saved or thrown away, e.g. because the app closed, comes back
    /// the next time its script is opened.
    private func offerUnsavedTake() async {
        guard cameraService.finishedTake == nil, !cameraService.isRecording,
              let take = await TakeStore.unsavedTakes(for: currentScript.id).last,
              cameraService.finishedTake == nil, !cameraService.isRecording else { return }
        cameraService.finishedTake = take
    }

    private func handlePlayModeAppear() {
        TabBarAnimator.setHidden(true, animated: true)
        WatchSessionRelay.shared.onCommandReceived = { command in
            handleWatchCommand(command)
        }
    }

    /// Nobody touches the screen while reading, recording or watching a take back,
    /// so it mustn't dim and lock then.
    private var keepsScreenAwake: Bool {
        viewModel.isPlaying || cameraService.isRecording || cameraService.finishedTake != nil
    }

    private func handlePlayModeDisappear() {
        // Covered by the take sheet, not left: the camera keeps running for Retake.
        guard cameraService.finishedTake == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        if !didRestoreTabBar {
            didRestoreTabBar = true
            TabBarAnimator.setHidden(false, animated: true)
        }
        saveLastProgress()
        viewModel.pause()
        stopCameraTask?.cancel()
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
        didRestoreTabBar = true
        TabBarAnimator.setHidden(false, animated: true)
        dismiss()
    }

    private func updateTimedDuration() {
        guard teleprompterMode == .timed else { return }
        let total = TimeInterval(timedMinutes * 60 + timedSeconds)
        viewModel.timedDuration = total > 0 ? total : 180
    }
    
    private var displayAdjustmentsPopover: some View {
        VStack(spacing: 16) {
            if !isUnderCamera, let words = viewModel.scriptWords, !words.isRightToLeft {
                Toggle(isOn: Binding(
                    get: { usesWordStyle },
                    set: { enabled in
                        guard storeKit.isPremium else {
                            showDisplayAdjustments = false
                            Task { @MainActor in
                                // A popover has to finish closing before the paywall can present.
                                try? await Task.sleep(for: .milliseconds(350))
                                showingPaywall = true
                            }
                            return
                        }
                        lyricsStyleEnabled = enabled
                    }
                )) {
                    Label("Lyrics Style", systemImage: storeKit.isPremium ? "music.note.list" : "lock.fill")
                        .font(.subheadline)
                }
                .tint(.accentColor)
                // Voice always highlights the word being read.
                .disabled(teleprompterMode == .voice)
            }
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                        .font(.caption).foregroundStyle(.secondary)
                    MusicSlider(
                        value: Binding(
                            get: { Double(liveHorizontalPadding) },
                            set: {
                                liveHorizontalPadding = CGFloat($0)
                                savedMargins = $0
                            }
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
                            set: {
                                liveFontSize = CGFloat($0)
                                ReadingPreferences.fontSize = CGFloat($0)
                            }
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

    private var timedDurationString: String {
        "\(timedMinutes):\(String(format: "%02d", timedSeconds))"
    }

    private func stepTimedDuration(by seconds: Int) {
        var total = timedMinutes * 60 + timedSeconds + seconds
        total = max(30, min(59 * 60 + 30, (total / 30) * 30))
        timedMinutes = total / 60
        timedSeconds = total % 60
        savedTimedSeconds = total
    }
    
    // MARK: - Modes

    private func selectMode(_ mode: TeleprompterMode) {
        guard mode != teleprompterMode else { return }
        if (mode == .voice || mode == .timed) && !storeKit.isPremium {
            showingPaywall = true
            return
        }
        if viewModel.isPlaying { viewModel.showControlsTemporarily() }

        switch teleprompterMode {
        case .tap:   viewModel.isTapToAdvance = false
        case .voice: if viewModel.voiceScrollEnabled { Task { await viewModel.toggleVoiceScroll() } }
        case .timed:
            viewModel.timedDuration = nil
            // Timed mode works out its own speed; go back to the reader's.
            applyReadingPreferences()
        case .auto:  break
        }

        switch mode {
        case .auto:
            break
        case .tap:
            // The reader moves the script in this mode, so nothing should scroll by itself.
            viewModel.pause()
            viewModel.isTapToAdvance = true
        case .voice:
            // Choosing the mode shouldn't start reading: pressing play does.
            Task {
                await viewModel.toggleVoiceScroll(autoPlay: false)
                // The reader moved on while the permission check was running.
                if teleprompterMode != .voice && viewModel.voiceScrollEnabled {
                    await viewModel.toggleVoiceScroll()
                }
            }
        case .timed:
            let total = TimeInterval(timedMinutes * 60 + timedSeconds)
            viewModel.timedDuration = total > 0 ? total : 180
        }
        teleprompterMode = mode
        savedMode = mode.rawValue
    }

    /// The reader's last speed, text size and margins, on every script.
    private func applyReadingPreferences() {
        viewModel.scrollSpeed = ReadingPreferences.speed > 0 ? ReadingPreferences.speed : customization.scrollSpeed
        liveFontSize = ReadingPreferences.fontSize > 0 ? ReadingPreferences.fontSize : customization.fontSize
        liveHorizontalPadding = CGFloat(savedMargins)
    }

    /// Opens the way the reader left it. A lapsed subscription falls back to the free options
    /// without forgetting the choice, so it returns if they subscribe again.
    private func restoreModeAndBackground() {
        timedMinutes = savedTimedSeconds / 60
        timedSeconds = savedTimedSeconds % 60

        let mode = TeleprompterMode(rawValue: savedMode) ?? .auto
        if mode != .auto && (storeKit.isPremium || mode == .tap) {
            let remembered = savedMode
            selectMode(mode)
            savedMode = remembered
        }
        if savedBackground == ReadingPreferences.cameraBackground && storeKit.isPremium {
            backgroundMode = .camera
            if !usesDemoCamera && !cameraService.isCameraActive {
                Task { await cameraService.requestPermissionsAndStart() }
            }
        }
        #if DEBUG
        // For App Store screenshots.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ypShotPlay") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                viewModel.play()
            }
        }
        if arguments.contains("-ypShotRecord") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                cameraService.toggleRecording()
            }
        }
        if arguments.contains("-ypShotPaywall") { showingPaywall = true }
        // The simulator has no camera: `-ypDemoTake <video file>` reviews that video as a take.
        if let flag = arguments.firstIndex(of: "-ypDemoTake"), arguments.indices.contains(flag + 1) {
            let take = TakeStore.newTake(scriptID: currentScript.id, startProgress: viewModel.progress)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[flag + 1]), to: take.url)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                cameraService.finishedTake = take
            }
        }
        #endif
    }

    // MARK: - Background

    private func selectBackground(_ mode: BackgroundMode) {
        if viewModel.isPlaying { viewModel.showControlsTemporarily() }
        guard mode != backgroundMode else { return }
        if mode == .camera {
            guard storeKit.isPremium else { showingPaywall = true; return }
            stopCameraTask?.cancel()
            // Still running if the reader came straight back from Color.
            if !usesDemoCamera && !cameraService.isCameraActive {
                Task { await cameraService.requestPermissionsAndStart() }
            }
        } else if backgroundMode == .camera {
            // Keep the preview running until it has faded out.
            stopCameraTask?.cancel()
            stopCameraTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                cameraService.stopCamera()
            }
        }
        savedBackground = mode == .camera ? ReadingPreferences.cameraBackground : ReadingPreferences.colorBackground
        withAnimation(surfaceAnimation) { backgroundMode = mode }
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
        .ypGlassEffect(cornerRadius: 24)
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
        lastCrossedCueProgress = -1
        print("[Queue] advanceToNextScript — now at index \(queueIndex): \"\(currentScript.title)\"")
        // Save the stale height before resetting so onHeights can skip it.
        viewModel.pendingAutoPlayStaleHeight = viewModel.contentHeight
        viewModel.prepareForNext(customization: currentScript.customization)
        applyReadingPreferences()
        viewModel.load(words: currentScript.scriptWords)
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
    private func textBody(textColor: Color? = nil, horizontalPadding: CGFloat = 16, topInset: CGFloat = 0) -> some View {
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
            .padding(.top, 24 + topInset)
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
                    step: 0.1,
                    requiresLongPress: sliderRequiresLongPress
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
#if os(iOS) || os(visionOS)
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

// MARK: - Word surface (iOS)

#if os(iOS)
/// Word-style text whose look follows the background and layout. SwiftUI interpolates the two
/// amounts frame by frame, so its color and position glide when either changes.
private struct AnimatedWordSurface: View, Animatable {
    let viewModel: TeleprompterViewModel
    let words: ScriptWords
    let fontSize: CGFloat
    let lineHeightMultiple: CGFloat
    let promptColor: Color
    let alignment: Int
    let horizontalPadding: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let isMirrored: Bool
    let onScrub: (Bool) -> Void
    /// 0 on a solid color, 1 with the camera behind the text.
    var cameraAmount: Double
    /// 0 full screen, 1 for the few lines under the camera.
    var underCameraAmount: Double

    @Environment(\.self) private var environment

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(cameraAmount, underCameraAmount) }
        set {
            cameraAmount = newValue.first
            underCameraAmount = newValue.second
        }
    }

    private var textColor: Color {
        let from = promptColor.resolve(in: environment)
        let amount = Float(cameraAmount)
        return Color(Color.Resolved(
            red: from.red + (1 - from.red) * amount,
            green: from.green + (1 - from.green) * amount,
            blue: from.blue + (1 - from.blue) * amount
        ))
    }

    var body: some View {
        WordTeleprompterView(
            viewModel: viewModel,
            words: words,
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            textColor: textColor,
            alignment: alignment,
            horizontalPadding: horizontalPadding,
            topInset: topInset,
            bottomInset: bottomInset,
            anchor: CGFloat(0.04 * (1 - underCameraAmount)),
            isMirrored: isMirrored,
            upcomingOpacity: 0.42 + 0.13 * cameraAmount,
            pastOpacity: 0.22 * (1 - underCameraAmount),
            onScrub: onScrub
        )
    }
}
#endif

// MARK: - UIScrollView-backed teleprompter (iOS)

#if os(iOS)
private final class _ScrollContainer: UIScrollView {
    var onLayout: ((CGFloat, CGFloat, Bool) -> Void)?
    private var lastWidth: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        let visibleHeight = bounds.height - adjustedContentInset.top
        guard contentSize.height > 0, visibleHeight > 0 else { return }
        let widthChanged = lastWidth > 0 && abs(bounds.width - lastWidth) > 0.5
        lastWidth = bounds.width
        onLayout?(contentSize.height, visibleHeight, widthChanged)
    }
}

private struct TeleprompterScrollView<Content: View>: UIViewRepresentable {
    @Binding var offset: CGFloat
    let content: Content
    let onHeights: (CGFloat, CGFloat, Bool) -> Void
    var bottomInset: CGFloat = 0
    var scriptID: UUID? = nil
    var fontSize: CGFloat = 0
    var horizontalPadding: CGFloat = 0
    var topInset: CGFloat = 0

    final class Coordinator {
        var hosting: UIHostingController<Content>?
        var lastScriptID: UUID? = nil
        var lastFontSize: CGFloat = 0
        var lastHorizontalPadding: CGFloat = 0
        var lastTopInset: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> _ScrollContainer {
        let sv = _ScrollContainer()
        sv.isScrollEnabled = false
        sv.showsVerticalScrollIndicator = false
        sv.backgroundColor = .clear
        // The text sets its own distance from the top, so the safe area isn't added on top of it.
        sv.contentInsetAdjustmentBehavior = .never
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
            || topInset != context.coordinator.lastTopInset
        if needsRelayout {
            context.coordinator.lastScriptID = scriptID
            context.coordinator.lastFontSize = fontSize
            context.coordinator.lastHorizontalPadding = horizontalPadding
            context.coordinator.lastTopInset = topInset
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
    let camera: CameraRecordingService

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        // The service's rotation coordinator keeps this layer (and recordings) level.
        camera.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        camera.attachPreviewLayer(uiView.previewLayer)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#endif

