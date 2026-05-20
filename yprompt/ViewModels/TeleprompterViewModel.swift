//
//  TeleprompterViewModel.swift
//  yprompt
//

import Foundation
import Combine
import SwiftUI

@MainActor
class TeleprompterViewModel: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var scrollSpeed: Double = 1.0
    @Published var contentOffset: CGFloat = 0
    @Published var transparency: Double = 1.0
    @Published var showControls: Bool = true
    @Published var isTapToAdvance: Bool = false

    var contentHeight: CGFloat = 0
    var screenHeight: CGFloat = 0

    private var scrollTask: Task<Void, Never>?
    private var hideControlsTask: Task<Void, Never>?

    // MARK: - Playback

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        startScrollTask()
        scheduleHideControls()
    }

    func pause() {
        isPlaying = false
        scrollTask?.cancel()
        scrollTask = nil
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func resetToTop() {
        pause()
        withAnimation(.easeOut(duration: 0.4)) {
            contentOffset = 0
        }
        showControls = true
        hideControlsTask?.cancel()
    }

    // MARK: - Tap to Advance

    func tapAdvance() {
        let advance = screenHeight * 0.3
        let maxOffset = max(0, contentHeight - screenHeight + 80)
        withAnimation(.easeInOut(duration: 0.3)) {
            contentOffset = min(contentOffset + advance, maxOffset)
        }
    }

    // MARK: - Controls Visibility

    func showControlsTemporarily() {
        withAnimation { showControls = true }
        scheduleHideControls()
    }

    // MARK: - Private

    private func startScrollTask() {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            while !Task.isCancelled {
                // ~60 fps
                try? await Task.sleep(nanoseconds: 16_666_667)
                guard !Task.isCancelled else { break }
                let pixelsPerTick = AppConstants.basePixelsPerSecond * scrollSpeed / 60.0
                let maxOffset = max(0, contentHeight - screenHeight + 80)
                if contentOffset < maxOffset {
                    contentOffset += pixelsPerTick
                } else {
                    pause()
                    break
                }
            }
        }
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showControls = false }
        }
    }

    deinit {
        scrollTask?.cancel()
        hideControlsTask?.cancel()
    }
}
