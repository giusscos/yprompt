//
//  FloatingTeleprompterManager.swift
//  yprompt
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingTeleprompterManager: ObservableObject {
    static let shared = FloatingTeleprompterManager()

    @Published var isVisible = false
    @Published var currentScript: Script?
    @Published var backgroundOpacity: Double = 0.92
    @Published var blurAmount: Double = 0.0
    @Published var notchMode: Bool = false
    @Published var notchFontSize: CGFloat = 11
    @Published var floatingFontSize: CGFloat = 19
    let viewModel = TeleprompterViewModel()

    var storeKit: StoreKitService?
    var isPremium: Bool { storeKit?.isPremium ?? false }

    // Published to NotchTeleprompterView for remote horizontal scroll
    let notchScrollDelta = PassthroughSubject<CGFloat, Never>()

    private var panel: NSPanel?
    private var notchPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var notchRemoteScrollTask: Task<Void, Never>?

    private init() {
        $notchFontSize
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateNotchPanelFrame() }
            .store(in: &cancellables)
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
        isVisible = true
    }

    func hide() {
        viewModel.pause()
        viewModel.stopContinuousScroll()
        stopNotchRemoteScroll()
        panel?.orderOut(nil)
        notchPanel?.orderOut(nil)
        isVisible = false
    }

    // MARK: - Remote Control

    private func setupRemoteControlCallbacks() {
        let remote = RemoteControlService.shared
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
            }
        }
        remote.onLastPeerDisconnected = { [weak self] in
            self?.viewModel.stopContinuousScroll()
            self?.stopNotchRemoteScroll()
        }
    }

    private func startNotchRemoteScroll(forward: Bool) {
        stopNotchRemoteScroll()
        notchRemoteScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_666_667)
                guard !Task.isCancelled else { break }
                let delta = AppConstants.basePixelsPerSecond * max(viewModel.scrollSpeed, 1.0) / 60.0
                // forward = text moves left = negative xOffset delta
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

        let panelWidth: CGFloat = 780
        let panelHeight: CGFloat = 116
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
}
#endif
