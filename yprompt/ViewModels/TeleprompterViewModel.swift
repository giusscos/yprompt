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
    @Published var voiceScrollEnabled: Bool = false
    @Published var showVoiceMeter: Bool = true
    @Published var micPermissionDenied: Bool = false

    #if !os(watchOS)
    let voiceScrollService = VoiceScrollService()
    #endif

    var contentHeight: CGFloat = 0
    var screenHeight: CGFloat = 0

    private var scrollTask: Task<Void, Never>?
    private var hideControlsTask: Task<Void, Never>?
    private var remoteScrollTask: Task<Void, Never>?

    // MARK: - Playback

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        #if !os(watchOS)
        if voiceScrollEnabled { voiceScrollService.start() }
        #endif
        startScrollTask()
        scheduleHideControls()
    }

    func pause() {
        isPlaying = false
        scrollTask?.cancel()
        scrollTask = nil
        #if !os(watchOS)
        voiceScrollService.stop()
        #endif
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func resetToTop() {
        pause()
        withAnimation(.easeOut(duration: 0.4)) { contentOffset = 0 }
        showControls = true
        hideControlsTask?.cancel()
    }

    // MARK: - Progress

    var progress: Double {
        guard contentHeight > screenHeight else { return 0 }
        let maxOffset = max(1, contentHeight - screenHeight + 80)
        return min(1.0, Double(contentOffset) / Double(maxOffset))
    }

    func seek(to fraction: Double) {
        let maxOffset = max(0, contentHeight - screenHeight + 80)
        withAnimation(.easeOut(duration: 0.2)) {
            contentOffset = maxOffset * CGFloat(fraction)
        }
    }

    // MARK: - Tap to Advance

    func tapAdvance() {
        let advance = screenHeight * 0.3
        let maxOffset = max(0, contentHeight - screenHeight + 80)
        withAnimation(.easeInOut(duration: 0.3)) {
            contentOffset = min(contentOffset + advance, maxOffset)
        }
    }

    // MARK: - Voice Scroll

    #if !os(watchOS)
    func toggleVoiceScroll() async {
        if voiceScrollEnabled {
            voiceScrollEnabled = false
            pause()
        } else {
            let granted = await voiceScrollService.requestPermission()
            if granted {
                voiceScrollEnabled = true
                showVoiceMeter = true
                play()
            } else {
                micPermissionDenied = true
            }
        }
    }
    #endif

    // MARK: - Remote Scroll

    enum RemoteScrollDirection { case forward, backward }

    func startContinuousScroll(direction: RemoteScrollDirection) {
        stopContinuousScroll()
        remoteScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_666_667)
                guard !Task.isCancelled else { break }
                let pixelsPerTick = AppConstants.basePixelsPerSecond * max(scrollSpeed, 1.0) / 60.0
                let maxOffset = max(0, contentHeight - screenHeight + 80)
                switch direction {
                case .forward:
                    contentOffset = min(contentOffset + pixelsPerTick, maxOffset)
                case .backward:
                    contentOffset = max(contentOffset - pixelsPerTick, 0)
                }
            }
        }
    }

    func stopContinuousScroll() {
        remoteScrollTask?.cancel()
        remoteScrollTask = nil
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
                try? await Task.sleep(nanoseconds: 16_666_667)
                guard !Task.isCancelled else { break }

                #if !os(watchOS)
                // In voice scroll mode, only advance while the user is speaking
                if voiceScrollEnabled && !voiceScrollService.isSpeaking { continue }
                #endif

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
        remoteScrollTask?.cancel()
    }
}
