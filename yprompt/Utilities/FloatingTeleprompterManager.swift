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
    var backgroundOpacity: Double = 0.92
    var blurAmount: Double = 0.0
    var notchMode: Bool = false
    var notchFontSize: CGFloat = 11 {
        didSet { updateNotchPanelFrame() }
    }
    var floatingFontSize: CGFloat = 19
    var showQueueBanner: Bool = false
    var queueCountdown: Int = 5
    var floatingWindowWidth: CGFloat = 780 {
        didSet { resizeFloatingPanel(width: floatingWindowWidth, height: floatingWindowHeight) }
    }
    var floatingWindowHeight: CGFloat = 116 {
        didSet { resizeFloatingPanel(width: floatingWindowWidth, height: floatingWindowHeight) }
    }
    var horizontalPadding: CGFloat = 52
    let viewModel = TeleprompterViewModel()

    var storeKit: StoreKitService?
    var isPremium: Bool { storeKit?.isPremium ?? false }

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

    private init() {
        viewModel.onFinished = { [weak self] in
            guard let self, self.nextInQueue != nil else { return }
            self.showQueueBanner = true
            self.startQueueCountdown()
        }
        setupRemoteControlCallbacks()
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
        viewModel.isNotchMode = notchMode
        viewModel.resetToTop()
        if notchMode {
            panel?.orderOut(nil)
            if notchPanel == nil { buildNotchPanel() }
            notchPanel?.orderFront(nil)
        } else {
            notchPanel?.orderOut(nil)
            if panel == nil { buildPanel() }
            panel?.orderFront(nil)
        }
        startArrowKeyMonitor()
        isVisible = true
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
        viewModel.isNotchMode = notch
        guard isVisible else { return }
        if notch {
            panel?.orderOut(nil)
            if notchPanel == nil { buildNotchPanel() }
            notchPanel?.orderFront(nil)
        } else {
            notchPanel?.orderOut(nil)
            if panel == nil { buildPanel() }
            panel?.orderFront(nil)
        }
    }

    func hide() {
        viewModel.pause()
        viewModel.stopContinuousScroll()
        stopNotchRemoteScroll()
        stopArrowKeyMonitor()
        panel?.orderOut(nil)
        notchPanel?.orderOut(nil)
        isVisible = false
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
        newPanel.minSize = CGSize(width: 340, height: 72)
        newPanel.maxSize = CGSize(width: screen.frame.width, height: 340)

        let hostView = NSHostingView(rootView: FloatingTeleprompterView())
        hostView.frame = newPanel.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        newPanel.contentView = hostView
        panel = newPanel
    }

    private func notchPanelFrame() -> CGRect {
        guard let screen = NSScreen.main else { return .zero }
        let sf = screen.frame
        let menuBarH = NSStatusBar.system.thickness
        let textBandH = notchFontSize + 19
        let panelWidth: CGFloat = 260
        let panelHeight = menuBarH + textBandH
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
        hostView.frame = newPanel.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        newPanel.contentView = hostView
        notchPanel = newPanel
    }

    private func updateNotchPanelFrame() {
        guard let panel = notchPanel else { return }
        panel.setFrame(notchPanelFrame(), display: true, animate: false)
    }

    private func resizeFloatingPanel(width: CGFloat, height: CGFloat) {
        guard let panel, let screen = NSScreen.main else { return }
        let sf = screen.frame
        let menuBarThickness = NSStatusBar.system.thickness
        let originX = sf.minX + (sf.width - width) / 2
        let originY = sf.maxY - height - menuBarThickness - 2
        panel.setFrame(CGRect(x: originX, y: originY, width: width, height: height), display: true, animate: true)
    }
}
#endif
