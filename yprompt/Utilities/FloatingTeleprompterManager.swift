//
//  FloatingTeleprompterManager.swift
//  yprompt
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI

@Observable @MainActor
final class FloatingTeleprompterManager {
    static let shared = FloatingTeleprompterManager()

    var isVisible = false
    var currentScript: Script?
    var backgroundOpacity: Double = UserDefaults.standard.object(forKey: "floating.opacity") as? Double ?? 0.92 {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: "floating.opacity") }
    }
    var blurAmount: Double = UserDefaults.standard.double(forKey: "floating.blur") {
        didSet { UserDefaults.standard.set(blurAmount, forKey: "floating.blur") }
    }
    var notchMode: Bool = false
    /// Drives the notch bounce appear/disappear spring in `NotchTeleprompterView`.
    var notchPresented: Bool = false
    var notchFontSize: CGFloat = 11 {
        didSet { updateNotchPanelFrame() }
    }
    /// Vertical multiline scroll in the notch (vs horizontal ticker).
    var notchScrollVertical: Bool = false {
        didSet { updateNotchPanelFrame() }
    }

    /// User-facing orientation change; bounces the notch when it's on screen.
    func setNotchScrollVertical(_ vertical: Bool) {
        if !isVisible || !notchMode {
            notchScrollVertical = vertical
            return
        }
        if vertical == notchScrollVertical, notchPresented, notchAnimationTask == nil {
            return
        }

        notchAnimationTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            notchPresented = false
        }
        let target = vertical
        notchAnimationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 340_000_000)
            guard !Task.isCancelled else { return }
            notchScrollVertical = target
            notchPanel?.orderFront(nil)
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
                notchPresented = true
            }
        }
    }

    static let notchTopRadius: CGFloat = 12

    /// The black strip the text sits under: as tall as the screen's notch, so no letter is
    /// hidden behind it, plus a little air. `NSStatusBar.thickness` is shorter than the notch.
    static var notchStripHeight: CGFloat {
        let notch = NSScreen.main?.safeAreaInsets.top ?? 0
        return max(NSStatusBar.system.thickness, notch) + 3
    }
    /// Bottom corners, concentric with what's inside: the one-line ticker matches the hardware
    /// notch's own tight corners; taller text gets a little more; with the camera the outer
    /// radius is the picture's plus the inset between them.
    static let notchTickerBottomRadius: CGFloat = 10
    static let notchBottomRadius: CGFloat = 14
    static let notchBodyWidth: CGFloat = 260
    /// Extra panel height below the silhouette so spring overshoot isn't window-clipped.
    static let notchBounceSlack: CGFloat = 28
    /// Space between the camera picture and the notch's sides and bottom.
    static let notchCameraInset: CGFloat = 8
    /// The notch's bottom corners while it holds the camera, so the picture's corners
    /// (this minus the inset) run parallel to them.
    static let notchCameraBottomRadius: CGFloat = 20
    /// The camera picture: 16:9 across the notch's body, inside the inset.
    static var notchCameraPictureHeight: CGFloat {
        ((notchBodyWidth - 2 * notchCameraInset) * 9 / 16).rounded()
    }
    /// The camera's share of the notch, below the text: the picture and the inset under it.
    static var notchCameraHeight: CGFloat { notchCameraPictureHeight + notchCameraInset }
    /// The tallest the text band gets: vertical scrolling at the largest text size.
    static let notchMaxTextBand: CGFloat = 32 * 5 + 28
    var floatingFontSize: CGFloat = 19
    var showQueueBanner: Bool = false
    var queueCountdown: Int = 5
    var floatingWindowWidth: CGFloat = 780 {
        didSet { resizeFloatingPanel(width: floatingWindowWidth, height: floatingWindowHeight) }
    }
    var floatingWindowHeight: CGFloat = 116 {
        didSet { resizeFloatingPanel(width: floatingWindowWidth, height: floatingWindowHeight) }
    }
    var horizontalPadding: CGFloat = (UserDefaults.standard.object(forKey: "floating.margins") as? Double).map { CGFloat($0) } ?? 52 {
        didSet { UserDefaults.standard.set(Double(horizontalPadding), forKey: "floating.margins") }
    }
    let viewModel = TeleprompterViewModel()

    // MARK: Recording

    enum RecordMode: String, CaseIterable, Identifiable {
        case off, camera, audio
        var id: String { rawValue }
    }

    let capture = MacCaptureService()
    /// What the prompter records with. The camera or microphone only runs while the prompter shows.
    var recordMode: RecordMode = RecordMode(rawValue: UserDefaults.standard.string(forKey: "mac.recordMode") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(recordMode.rawValue, forKey: "mac.recordMode")
            if recordMode != oldValue { applyRecordMode() }
        }
    }
    /// The camera preview window, which can be hidden while the camera stays on.
    var showsCameraPreview: Bool = UserDefaults.standard.object(forKey: "mac.cameraPreview") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsCameraPreview, forKey: "mac.cameraPreview")
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { updatePreviewPanel() }
        }
    }
    /// Shows the camera like a mirror, as people expect to see themselves. Recordings never are.
    var mirrorsCamera: Bool = UserDefaults.standard.object(forKey: AppConstants.mirrorCameraKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(mirrorsCamera, forKey: AppConstants.mirrorCameraKey) }
    }
    /// Where the next take goes when recording more into an existing recording.
    var pendingPickup: Pickup?
    /// A finished take for the main window to open in the editor.
    var requestedRecording: RecordingSelection?
    /// Opens the main window when it's closed; set by the SwiftUI scenes that can open windows.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    var storeKit: StoreKitService?
    var isPremium: Bool { storeKit?.isPremium ?? false }
    /// Opens the paywall window; set by the SwiftUI scenes that can open windows.
    @ObservationIgnored var presentPaywall: (() -> Void)?
    var paywallContext: PaywallView.Context = .upgrade

    /// Asks to upgrade from places with no way to present a sheet, like the menu bar.
    func showPaywall(context: PaywallView.Context = .upgrade) {
        paywallContext = context
        presentPaywall?()
    }

    private var queue: [Script] = []
    private var queueIndex: Int = 0
    var nextInQueue: Script? { queueIndex + 1 < queue.count ? queue[queueIndex + 1] : nil }

    @ObservationIgnored let notchScrollDelta = PassthroughSubject<CGFloat, Never>()

    /// All scripts on the Mac — kept in sync by ContentView so the remote can list and select them.
    var registeredScripts: [Script] = [] {
        didSet {
            let infos = registeredScripts.map { ScriptInfo(id: $0.id, title: $0.title) }
            let remote = RemoteControlService.shared
            for peer in remote.connectedPeers {
                remote.sendScriptList(infos, currentID: currentScript?.id, notchMode: notchMode,
                                     voiceScrollEnabled: viewModel.voiceScrollEnabled,
                                     timedDuration: viewModel.timedDuration, to: peer)
            }
        }
    }

    var suppressModeRestart = false

    private var panel: NSPanel?
    private var notchPanel: NSPanel?
    private var keyEventMonitor: Any?
    private var notchRemoteScrollTask: Task<Void, Never>?
    private var queueCountdownTask: Task<Void, Never>?
    private var notchAnimationTask: Task<Void, Never>?

    private init() {
        viewModel.onFinished = { [weak self] in
            guard let self else { return }
            if self.nextInQueue != nil {
                self.showQueueBanner = true
                self.startQueueCountdown()
            } else if !self.isPremium && RatingService.shared.claimFirstReadPaywall() {
                self.showPaywall(context: .firstRead)
            }
        }
        setupRemoteControlCallbacks()
        capture.onFinished = { [weak self] selection in self?.takeFinished(selection) }
    }

    static var screenHasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }

    func show(script: Script, storeKit: StoreKitService? = nil) {
        currentScript = script
        if let storeKit { self.storeKit = storeKit }
        // A saved notch preference from before notch mode became Pro, or a lapsed subscription.
        if notchMode && !isPremium { notchMode = false }
        viewModel.load(words: script.scriptWords)
        viewModel.scrollSpeed = ReadingPreferences.speed > 0 ? ReadingPreferences.speed : script.customization.scrollSpeed
        viewModel.isNotchMode = notchMode
        viewModel.resetToTop()
        let alreadyShowingNotch = isVisible && notchMode && notchPresented
        if notchMode {
            panel?.orderOut(nil)
            if notchPanel == nil { buildNotchPanel() }
            if alreadyShowingNotch {
                notchPanel?.orderFront(nil)
            } else {
                animateNotchIn()
            }
        } else {
            notchPresented = false
            notchPanel?.orderOut(nil)
            if panel == nil { buildPanel() }
            panel?.orderFront(nil)
        }
        startArrowKeyMonitor()
        isVisible = true
        applyRecordMode()
    }

    func showQueue(scripts: [Script], storeKit: StoreKitService? = nil) {
        guard !scripts.isEmpty else { return }
        queue = scripts
        queueIndex = 0
        show(script: scripts[0], storeKit: storeKit)
    }

    func advanceQueue() {
        queueCountdownTask?.cancel()
        showQueueBanner = false
        queueIndex += 1
        guard queueIndex < queue.count else { return }
        currentScript = queue[queueIndex]
        viewModel.load(words: queue[queueIndex].scriptWords)
        viewModel.resetForNext()
        viewModel.play()
    }

    func cancelQueueBanner() {
        queueCountdownTask?.cancel()
        showQueueBanner = false
    }

    private func startQueueCountdown() {
        queueCountdown = 5
        queueCountdownTask?.cancel()
        queueCountdownTask = Task { @MainActor in
            for i in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                queueCountdown = i
            }
            guard !Task.isCancelled else { return }
            advanceQueue()
        }
    }

    func switchDisplayMode(notch: Bool) {
        suppressModeRestart = true
        notchMode = notch
        applyVisibleModeChange()
    }

    /// Swaps floating ↔ notch panels for an already-visible teleprompter.
    /// Assumes `notchMode` is already set (e.g. by a picker binding).
    func applyVisibleModeChange() {
        viewModel.isNotchMode = notchMode
        updatePreviewPanel()
        guard isVisible else { return }
        if notchMode {
            panel?.orderOut(nil)
            if notchPanel == nil { buildNotchPanel() }
            animateNotchIn()
        } else {
            animateNotchOut {
                if self.panel == nil { self.buildPanel() }
                self.panel?.orderFront(nil)
            }
        }
    }

    func hide() {
        // A take being recorded is finished and kept.
        capture.stop()
        pendingPickup = nil
        updatePreviewPanel()
        viewModel.pause()
        viewModel.stopContinuousScroll()
        stopNotchRemoteScroll()
        stopArrowKeyMonitor()
        panel?.orderOut(nil)
        isVisible = false
        if notchPresented {
            animateNotchOut()
        } else {
            notchPanel?.orderOut(nil)
        }
    }

    // MARK: - Notch appear / disappear bounce

    private func animateNotchIn() {
        notchAnimationTask?.cancel()
        notchPresented = false
        notchPanel?.orderFront(nil)
        notchAnimationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
                notchPresented = true
            }
        }
    }

    private func animateNotchOut(completion: (() -> Void)? = nil) {
        notchAnimationTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            notchPresented = false
        }
        notchAnimationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 340_000_000)
            guard !Task.isCancelled else { return }
            notchPanel?.orderOut(nil)
            completion?()
        }
    }

    // MARK: - Arrow Key Monitor (↑↓ always active while visible)

    private func startArrowKeyMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return }
            switch event.keyCode {
            case 126: Task { @MainActor in self.viewModel.tapReverse() }   // ↑
            case 125: Task { @MainActor in self.viewModel.tapAdvance() }   // ↓
            default: break
            }
        }
    }

    private func stopArrowKeyMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    // MARK: - Recording

    /// Starts or stops the camera or microphone to match `recordMode`, while the prompter shows.
    private func applyRecordMode() {
        guard isVisible, recordMode != .off else {
            capture.stop()
            updatePreviewPanel()
            return
        }
        let audioOnly = recordMode == .audio
        Task { @MainActor in
            await capture.requestPermissionsAndStart(audioOnly: audioOnly)
            updatePreviewPanel()
        }
    }

    /// One button for the take: recording and reading start and stop together, as on iPhone.
    /// With recording off, it turns the camera on first.
    func toggleRecording() {
        guard let script = currentScript else { return }
        Task { @MainActor in
            if recordMode == .off { recordMode = .camera }
            if !capture.isActive {
                await capture.requestPermissionsAndStart(audioOnly: recordMode == .audio)
                updatePreviewPanel()
            }
            guard capture.isActive else { return }
            let starting = !capture.isRecording
            let target = RecordingTarget(scriptID: script.id, title: script.title,
                                         recordingID: pendingPickup?.recordingID, insertAt: pendingPickup?.insertAt)
            capture.toggleRecording(into: target, progress: viewModel.progress)
            // A pickup is one take.
            if !starting { pendingPickup = nil }
            guard !viewModel.isTapToAdvance else { return }
            if starting { viewModel.play() } else { viewModel.pause() }
        }
    }

    /// From the editor: get ready to record the next piece where the last one stopped.
    func startPickup(_ pickup: Pickup, script: Script) {
        if capture.isRecording { return }
        show(script: script)
        pendingPickup = pickup
        recordMode = pickup.kind == .audio ? .audio : .camera
        viewModel.pause()
        Task { @MainActor in
            // The text has to be laid out before a position in it means anything.
            try? await Task.sleep(for: .milliseconds(350))
            viewModel.seek(to: pickup.progress)
        }
    }

    /// Opens a finished take in the editor.
    func takeFinished(_ selection: RecordingSelection) {
        capture.finished = nil
        // The editor takes over, as on iPhone; Record More brings the prompter back.
        if isVisible { hide() }
        requestedRecording = selection
        NSApp.activate(ignoringOtherApps: true)
        let mainWindowOpen = NSApp.windows.contains {
            $0.isVisible && ($0.identifier?.rawValue.hasPrefix(AppConstants.mainWindowID) ?? false)
        }
        if !mainWindowOpen { openMainWindow?() }
    }

    private var previewPanel: NSPanel?

    private func updatePreviewPanel() {
        // In the notch, the preview sits inside the notch itself.
        let shows = isVisible && !notchMode && recordMode == .camera && capture.isActive && showsCameraPreview
        guard shows else {
            // A child window would come back with its parent: let go of it before hiding it.
            if let preview = previewPanel {
                preview.parent?.removeChildWindow(preview)
                preview.orderOut(nil)
            }
            return
        }
        if previewPanel == nil { buildPreviewPanel() }
        guard let preview = previewPanel else { return }
        // A child window moves with the prompter when it's dragged.
        if let panel, preview.parent !== panel {
            preview.parent?.removeChildWindow(preview)
            placePreview()
            panel.addChildWindow(preview, ordered: .above)
        }
        preview.orderFront(nil)
    }

    private func buildPreviewPanel() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let width: CGFloat = 320, height: CGFloat = 180
        // First time: just below the prompter, so the eyes stay near the camera.
        let prompterHeight = notchMode ? notchTextBandHeight() : floatingWindowHeight
        let originY = sf.maxY - NSStatusBar.system.thickness - prompterHeight - 16 - height
        let newPanel = NSPanel(
            contentRect: CGRect(x: sf.midX - width / 2, y: originY, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        newPanel.isMovableByWindowBackground = true
        newPanel.contentAspectRatio = CGSize(width: 16, height: 9)
        newPanel.minSize = Self.previewMinSize
        newPanel.maxSize = CGSize(width: 960, height: 540)
        newPanel.delegate = previewSizeLimiter
        if let saved = UserDefaults.standard.string(forKey: "floating.previewSize") {
            let size = NSSizeFromString(saved)
            if size.width >= Self.previewMinSize.width { newPanel.setContentSize(size) }
        }

        let hostView = MovableHostingView(rootView: CameraPreviewWindowView())
        // The window sets the size; SwiftUI content asking for its own size loops AppKit's layout.
        hostView.sizingOptions = []
        hostView.frame = newPanel.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        newPanel.contentView = Self.container(for: hostView, in: newPanel)
        previewPanel = newPanel

        // Resizing the preview from its edges keeps its new size and spot once the resize ends.
        // (Dragging and the corner grip are handled by begin/endPreviewAdjustment.)
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: newPanel, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, let preview = self.previewPanel else { return }
                    self.previewOffset = CGPoint(x: preview.frame.midX - panel.frame.midX,
                                                 y: panel.frame.minY - preview.frame.maxY)
                    UserDefaults.standard.set(NSStringFromPoint(self.previewOffset), forKey: Self.previewOffsetKey)
                    UserDefaults.standard.set(NSStringFromSize(preview.frame.size), forKey: "floating.previewSize")
                    self.placePreview()
                }
            }
        })
    }

    // MARK: - Remote Control

    private func setupRemoteControlCallbacks() {
        let remote = RemoteControlService.shared
        remote.onPeerConnected = { [weak self] peer in
            guard let self else { return }
            let infos = self.registeredScripts.map { ScriptInfo(id: $0.id, title: $0.title) }
            remote.sendScriptList(infos, currentID: self.currentScript?.id, notchMode: self.notchMode,
                                  voiceScrollEnabled: self.viewModel.voiceScrollEnabled,
                                  timedDuration: self.viewModel.timedDuration, to: peer)
        }
        remote.onCommandReceived = { [weak self] command in
            guard let self else { return }
            switch command {
            case .startContinuousDown:
                if self.notchMode { self.startNotchRemoteScroll(forward: true) }
                else { self.viewModel.startContinuousScroll(direction: .forward) }
            case .startContinuousUp:
                if self.notchMode { self.startNotchRemoteScroll(forward: false) }
                else { self.viewModel.startContinuousScroll(direction: .backward) }
            case .stopContinuous:
                self.viewModel.stopContinuousScroll()
                self.stopNotchRemoteScroll()
            case .togglePlayPause:
                self.viewModel.togglePlayPause()
            case .reset:
                self.viewModel.resetToTop()
            case .setSpeed(let speed):
                self.viewModel.scrollSpeed = max(AppConstants.minScrollSpeed, min(AppConstants.maxScrollSpeed, speed))
            case .selectScript(let id):
                if let script = self.registeredScripts.first(where: { $0.id == id }) {
                    self.show(script: script)
                }
            case .setNotchMode(let isNotch):
                guard !isNotch || self.isPremium else {
                    self.pushStateToRemotes(notchMode: self.notchMode)
                    return
                }
                self.switchDisplayMode(notch: isNotch)
                self.pushStateToRemotes(notchMode: isNotch)
            case .setVoiceScroll(let enabled):
                if enabled != self.viewModel.voiceScrollEnabled {
                    Task { await self.viewModel.toggleVoiceScroll() }
                }
                self.pushStateToRemotes(notchMode: self.notchMode)
            case .setTimedDuration(let duration):
                self.viewModel.timedDuration = duration
                self.pushStateToRemotes(notchMode: self.notchMode)
            }
        }
        remote.onLastPeerDisconnected = { [weak self] in
            self?.viewModel.stopContinuousScroll()
            self?.stopNotchRemoteScroll()
        }
    }

    private func pushStateToRemotes(notchMode: Bool) {
        let infos = registeredScripts.map { ScriptInfo(id: $0.id, title: $0.title) }
        let remote = RemoteControlService.shared
        for peer in remote.connectedPeers {
            remote.sendScriptList(infos, currentID: currentScript?.id, notchMode: notchMode,
                                  voiceScrollEnabled: viewModel.voiceScrollEnabled,
                                  timedDuration: viewModel.timedDuration, to: peer)
        }
    }

    private func startNotchRemoteScroll(forward: Bool) {
        stopNotchRemoteScroll()
        notchRemoteScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_666_667)
                guard !Task.isCancelled else { break }
                let delta = AppConstants.basePixelsPerSecond * max(viewModel.scrollSpeed, 1.0) / 60.0
                notchScrollDelta.send(forward ? -delta : delta)
            }
        }
    }

    private func stopNotchRemoteScroll() {
        notchRemoteScrollTask?.cancel()
        notchRemoteScrollTask = nil
    }

    // MARK: - Panel construction

    private func buildPanel() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let menuBarThickness = NSStatusBar.system.thickness

        let panelWidth = floatingWindowWidth
        let panelHeight = floatingWindowHeight
        let originX = sf.minX + (sf.width - panelWidth) / 2
        let originY = sf.maxY - panelHeight - menuBarThickness - 2

        let newPanel = NSPanel(
            contentRect: CGRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        newPanel.isMovableByWindowBackground = true
        newPanel.minSize = Self.floatingMinSize
        newPanel.delegate = floatingSizeLimiter
        newPanel.maxSize = CGSize(width: screen.frame.width, height: 340)

        let hostView = MovableHostingView(rootView: FloatingTeleprompterView())
        // The window sets the size; SwiftUI content asking for its own size loops AppKit's layout.
        hostView.sizingOptions = []
        hostView.frame = newPanel.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        newPanel.contentView = Self.container(for: hostView, in: newPanel)
        // Back where it was last time, at the size chosen in Settings.
        if let saved = UserDefaults.standard.string(forKey: Self.floatingTopCenterKey) {
            let point = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) {
                newPanel.setFrameOrigin(CGPoint(x: point.x - panelWidth / 2, y: point.y - panelHeight))
            }
        }
        panel = newPanel
        observeFloatingPanel(newPanel)
    }

    /// Below these the text and the picture stop being useful.
    static let floatingMinSize = CGSize(width: 420, height: 84)
    static let previewMinSize = CGSize(width: 256, height: 144)

    /// Every way of resizing goes through these, so the windows never get smaller than their minimum.
    @ObservationIgnored private let floatingSizeLimiter = PanelSizeLimiter(
        minSize: floatingMinSize, maxSize: CGSize(width: 4000, height: 340), aspectRatio: nil)
    @ObservationIgnored private let previewSizeLimiter = PanelSizeLimiter(
        minSize: previewMinSize, maxSize: CGSize(width: 960, height: 540), aspectRatio: 16.0 / 9.0)

    private static let floatingTopCenterKey = "floating.topCenter"
    private static let previewOffsetKey = "floating.previewOffset"

    /// Where the camera preview sits relative to the prompter: from the prompter's middle to the
    /// preview's middle across, and the gap below the prompter's bottom edge.
    @ObservationIgnored private var previewOffset: CGPoint = {
        UserDefaults.standard.string(forKey: previewOffsetKey).map(NSPointFromString) ?? CGPoint(x: 0, y: 12)
    }()
    @ObservationIgnored private var isPlacingPreview = false
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []

    @ObservationIgnored private var positionSave: DispatchWorkItem?

    /// Saves where the prompter is once it has stopped moving, not on every step of a drag.
    private func scheduleFloatingPositionSave() {
        positionSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            guard let frame = self?.panel?.frame else { return }
            UserDefaults.standard.set(NSStringFromPoint(CGPoint(x: frame.midX, y: frame.maxY)),
                                      forKey: Self.floatingTopCenterKey)
        }
        positionSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: save)
    }

    private func observeFloatingPanel(_ panel: NSPanel) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            windowObservers.append(center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The prompter is what's moving now, carrying the preview along.
                    self.isUserAdjustingPreview = false
                    // These run while AppKit lays the window out. Changing anything that SwiftUI
                    // watches from here (a saved setting, another window's frame) asks for yet
                    // another layout pass, until AppKit gives up and crashes. So: next turn.
                    DispatchQueue.main.async { self.placePreview() }
                    self.scheduleFloatingPositionSave()
                }
            })
        }
    }

    /// Set while the person drags or resizes the preview itself, so its new spot is kept.
    @ObservationIgnored private var isUserAdjustingPreview = false

    @ObservationIgnored private var adjustmentWatch: Timer?

    /// The preview window's drag area and resize grip call this as the person grabs it. The
    /// preview is let go of the prompter while it moves, so the drag stays smooth, and
    /// attached again where it was dropped once the mouse button comes up.
    func beginPreviewAdjustment() {
        guard let preview = previewPanel else { return }
        isUserAdjustingPreview = true
        preview.parent?.removeChildWindow(preview)
        adjustmentWatch?.invalidate()
        adjustmentWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            MainActor.assumeIsolated { self?.endPreviewAdjustment() }
        }
    }

    private func endPreviewAdjustment() {
        adjustmentWatch = nil
        guard isUserAdjustingPreview, let panel, let preview = previewPanel else { return }
        isUserAdjustingPreview = false
        previewOffset = CGPoint(x: preview.frame.midX - panel.frame.midX, y: panel.frame.minY - preview.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(previewOffset), forKey: Self.previewOffsetKey)
        UserDefaults.standard.set(NSStringFromSize(preview.frame.size), forKey: "floating.previewSize")
        placePreview()
        if preview.isVisible, preview.parent == nil { panel.addChildWindow(preview, ordered: .above) }
    }

    /// Puts the preview at its spot under the prompter. Where that spot would cross an edge of
    /// the screen, the preview goes to the other side of the prompter instead: above it near
    /// the bottom of the screen, to the other side near the left or right edge.
    private func placePreview() {
        guard let panel, let preview = previewPanel else { return }
        let size = preview.frame.size
        let prompter = panel.frame
        var frame = CGRect(x: prompter.midX + previewOffset.x - size.width / 2,
                           y: prompter.minY - previewOffset.y - size.height,
                           width: size.width, height: size.height)
        if let screen = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if frame.minY < screen.minY || frame.maxY > screen.maxY {
                frame.origin.y = 2 * prompter.midY - frame.midY - size.height / 2
            }
            if frame.minX < screen.minX || frame.maxX > screen.maxX {
                frame.origin.x = 2 * prompter.midX - frame.midX - size.width / 2
            }
            // Still off screen (a very big preview): keep as much of it on screen as possible.
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - size.height)
        }
        guard frame.origin != preview.frame.origin else { return }
        isPlacingPreview = true
        preview.setFrameOrigin(frame.origin)
        isPlacingPreview = false
    }

    /// The camera preview shows inside the notch rather than in its own window.
    var notchShowsCamera: Bool {
        notchMode && recordMode == .camera && capture.isActive && showsCameraPreview
    }

    func notchTextBandHeight() -> CGFloat {
        notchScrollVertical
            ? max(88, notchFontSize * 5 + 28)
            : notchFontSize + 19
    }

    private func notchPanelFrame() -> CGRect {
        guard let screen = NSScreen.main else { return .zero }
        let sf = screen.frame
        let menuBarH = Self.notchStripHeight
        // Extra width for inverted top-corner “ears”
        let panelWidth = Self.notchBodyWidth + 2 * Self.notchTopRadius
        // Room for the tallest the notch gets, so it can grow and shrink smoothly inside the
        // window instead of the window jumping. The empty part lets clicks through.
        // Slack below lets the bounce overshoot draw rounded bottoms without a hard clip.
        let panelHeight = menuBarH + Self.notchMaxTextBand + Self.notchCameraHeight + Self.notchBounceSlack
        let originX = sf.minX + (sf.width - panelWidth) / 2
        let originY = sf.maxY - panelHeight
        return CGRect(x: originX, y: originY, width: panelWidth, height: panelHeight)
    }

    private func buildNotchPanel() {
        let frame = notchPanelFrame()
        guard frame != .zero else { return }

        let newPanel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.screenSaver.rawValue))
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let hostView = NSHostingView(rootView: NotchTeleprompterView())
        // The window sets the size; SwiftUI content asking for its own size loops AppKit's layout.
        hostView.sizingOptions = []
        hostView.frame = newPanel.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        newPanel.contentView = Self.container(for: hostView, in: newPanel)
        notchPanel = newPanel
        // The window is as tall as the notch can get; only the notch itself takes clicks.
        notchMouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateNotchMouseHandling() }
        }
    }

    @ObservationIgnored private var notchMouseTimer: Timer?

    private func updateNotchMouseHandling() {
        guard let panel = notchPanel, panel.isVisible else { return }
        let frame = panel.frame
        let height = Self.notchStripHeight + notchTextBandHeight()
            + (notchShowsCamera ? Self.notchCameraHeight : 0)
        let notch = CGRect(x: frame.minX + Self.notchTopRadius, y: frame.maxY - height,
                           width: frame.width - 2 * Self.notchTopRadius, height: height)
        let inside = notch.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    private func updateNotchPanelFrame() {
        guard let panel = notchPanel else { return }
        panel.setFrame(notchPanelFrame(), display: true, animate: false)
    }

    private func resizeFloatingPanel(width: CGFloat, height: CGFloat) {
        guard let panel, let screen = NSScreen.main else { return }
        let sf = screen.frame
        let menuBarThickness = NSStatusBar.system.thickness
        // Grows and shrinks around where it is now: same top edge and middle.
        var frame = CGRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY - height, width: width, height: height)
        // Kept below the menu bar and on screen.
        frame.origin.y = min(frame.origin.y, sf.maxY - menuBarThickness - 2 - height)
        frame.origin.x = min(max(frame.origin.x, sf.minX), sf.maxX - width)
        panel.setFrame(frame, display: true, animate: true)
    }
}

extension FloatingTeleprompterManager {
    /// Puts SwiftUI content in a plain view that fills the window. As the window's own content
    /// view, a hosting view resizes the window after every layout pass, which fights any other
    /// resize (the corner grip, the size limits) until AppKit gives up and crashes. As a
    /// subview it just follows the window.
    static func container(for hostView: NSView, in window: NSWindow) -> NSView {
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        hostView.frame = container.bounds
        hostView.autoresizingMask = [.width, .height]
        container.addSubview(hostView)
        return container
    }
}

/// A hosting view that lets the window be dragged from anywhere on it, for the floating
/// prompter and the camera preview, which have no title bar.
final class MovableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Keeps a borderless window between its minimum and maximum size, and at its aspect ratio,
/// whichever way it's resized: its edges ignore `minSize` without a title bar.
final class PanelSizeLimiter: NSObject, NSWindowDelegate {
    let minSize: CGSize
    let maxSize: CGSize
    let aspectRatio: CGFloat?
    private var isCorrecting = false

    init(minSize: CGSize, maxSize: CGSize, aspectRatio: CGFloat?) {
        self.minSize = minSize
        self.maxSize = maxSize
        self.aspectRatio = aspectRatio
    }

    /// The nearest allowed size.
    func clamp(_ size: CGSize) -> CGSize {
        var width = min(max(size.width, minSize.width), maxSize.width)
        var height = min(max(size.height, minSize.height), maxSize.height)
        if let aspectRatio {
            height = (width / aspectRatio).rounded()
            if height < minSize.height {
                height = minSize.height
                width = (height * aspectRatio).rounded()
            }
        }
        return CGSize(width: width, height: height)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        clamp(frameSize)
    }

    /// A last safety net for resizes that skip the question above: put it back, top left fixed.
    func windowDidResize(_ notification: Notification) {
        guard !isCorrecting, let window = notification.object as? NSWindow else { return }
        let allowed = clamp(window.frame.size)
        guard abs(allowed.width - window.frame.width) > 0.5 || abs(allowed.height - window.frame.height) > 0.5 else { return }
        // Not from inside the resize itself: that would start another layout pass.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, !self.isCorrecting else { return }
            let allowed = self.clamp(window.frame.size)
            self.isCorrecting = true
            window.setFrame(CGRect(x: window.frame.minX, y: window.frame.maxY - allowed.height,
                                   width: allowed.width, height: allowed.height), display: true)
            self.isCorrecting = false
        }
    }
}
#endif
