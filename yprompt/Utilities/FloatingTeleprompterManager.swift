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
    let viewModel = TeleprompterViewModel()

    var storeKit: StoreKitService?
    var isPremium: Bool { storeKit?.isPremium ?? false }

    private var panel: NSPanel?

    private init() {}

    func show(script: Script, storeKit: StoreKitService? = nil) {
        currentScript = script
        if let storeKit { self.storeKit = storeKit }
        viewModel.resetToTop()
        if panel == nil { buildPanel() }
        panel?.orderFront(nil)
        isVisible = true
    }

    func hide() {
        viewModel.pause()
        panel?.orderOut(nil)
        isVisible = false
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
}
#endif
