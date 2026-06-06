//
//  TeleprompterViewModel.swift
//  yprompt
//

import Foundation
import Combine
import SwiftUI

@Observable @MainActor
class TeleprompterViewModel {
    var isPlaying: Bool = false
    var scrollSpeed: Double = 1.0
    var contentOffset: CGFloat = 0
    var transparency: Double = 1.0
    var showControls: Bool = true
    var isTapToAdvance: Bool = false
    var voiceScrollEnabled: Bool = false
    var showVoiceMeter: Bool = true
    var micPermissionDenied: Bool = false
    var isFinished: Bool = false
    // Notch mode horizontal progress (0→1 over text width before looping)
    var notchProgress: Double = 0
    // Explicit flag set by FloatingTeleprompterManager; avoids relying on stale contentHeight
    var isNotchMode: Bool = false

    // Timed scrolling: when set, play() auto-computes scrollSpeed to finish in this duration
    var timedDuration: TimeInterval? = nil
    // Wall-clock seconds elapsed while playing (used for notch mode remaining time)
    var elapsedPlayTime: TimeInterval = 0
    // Fires when resetToTop() is called so notch view can reset its xOffset
    @ObservationIgnored let resetPublisher = PassthroughSubject<Void, Never>()
    // Fires a 0…1 fraction for NotchTeleprompterView to jump its horizontal position
    @ObservationIgnored let notchSeekRequest = PassthroughSubject<Double, Never>()

    // Called when the script finishes scrolling; FloatingTeleprompterManager uses this for queue logic.
    var onFinished: (() -> Void)?

    var remainingTime: TimeInterval {
        guard let duration = timedDuration else { return 0 }
        // Floating mode: position-based remaining
        if !isNotchMode {
            let maxOffset = max(0, Double(contentHeight - screenHeight) + 80)
            let remaining = maxOffset - Double(contentOffset)
            return max(0, remaining / (Double(AppConstants.basePixelsPerSecond) * max(scrollSpeed, 0.01)))
        }
        // Notch mode (horizontal scrolling, no vertical extent): wall-clock remaining
        return max(0, duration - elapsedPlayTime)
    }

    #if !os(watchOS)
    let voiceScrollService = VoiceScrollService()
    #endif

    var contentHeight: CGFloat = 0
    var screenHeight: CGFloat = 0

    // Non-published: used to defer auto-play until the correct post-advance height is measured.
    // Set by the caller before play(); cleared when the real height arrives or on timeout.
    var pendingAutoPlay: Bool = false
    var pendingAutoPlayStaleHeight: CGFloat = 0

    @ObservationIgnored nonisolated(unsafe) private var scrollTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var hideControlsTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var remoteScrollTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var timedElapsedTask: Task<Void, Never>?

    // MARK: - Playback

    func play() {
        guard !isPlaying else { return }
        // Auto-compute speed so the script finishes in the requested duration (floating mode only)
        if let duration = timedDuration, duration > 0, contentHeight > screenHeight {
            let maxOffset = max(0, Double(contentHeight - screenHeight) + 80)
            let needed = maxOffset / (Double(AppConstants.basePixelsPerSecond) * duration)
            scrollSpeed = max(AppConstants.minScrollSpeed, min(AppConstants.maxScrollSpeed, needed))
        }
        isPlaying = true
        if timedDuration != nil { startTimedElapsedTask() }
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
        timedElapsedTask?.cancel()
        timedElapsedTask = nil
        #if !os(watchOS)
        voiceScrollService.stop()
        #endif
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func resetToTop() {
        pause()
        isFinished = false
        elapsedPlayTime = 0
        notchProgress = 0
        withAnimation(.easeOut(duration: 0.4)) { contentOffset = 0 }
        showControls = true
        hideControlsTask?.cancel()
        resetPublisher.send()
    }

    func prepareForNext(customization: TextCustomization) {
        print("[Queue] prepareForNext — resetting contentHeight from \(contentHeight) → 0")
        isFinished = false
        contentOffset = 0
        contentHeight = 0
        pendingAutoPlay = false
        scrollSpeed = customization.scrollSpeed
        transparency = customization.transparency
    }

    func resetForNext() {
        isFinished = false
        contentOffset = 0
        contentHeight = 0
        notchProgress = 0
        pendingAutoPlay = false
    }

    // MARK: - Progress

    var progress: Double {
        guard !isNotchMode else { return notchProgress }
        let maxOffset = max(1, contentHeight - screenHeight + 80)
        return min(1.0, Double(contentOffset) / Double(maxOffset))
    }

    func seek(to fraction: Double) {
        if isNotchMode {
            notchSeekRequest.send(fraction)
            return
        }
        let maxOffset = max(0, contentHeight - screenHeight + 80)
        withAnimation(.easeOut(duration: 0.2)) {
            contentOffset = maxOffset * CGFloat(fraction)
        }
    }

    // MARK: - Cue Points

    func jumpToCue(_ cue: CuePoint) {
        if isNotchMode {
            notchSeekRequest.send(cue.position)
            return
        }
        let maxOffset = max(0, contentHeight - screenHeight + 80)
        withAnimation(.easeOut(duration: 0.3)) {
            contentOffset = maxOffset * CGFloat(cue.position)
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

    func tapReverse() {
        let advance = screenHeight * 0.3
        withAnimation(.easeInOut(duration: 0.3)) {
            contentOffset = max(0, contentOffset - advance)
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

                // Notch mode scrolls horizontally via its own timer; skip the vertical task.
                guard !isNotchMode, contentHeight > 0 else {
                    if !isNotchMode { print("[Queue] scroll tick skipped — contentHeight=0 (waiting for layout)") }
                    continue
                }

                let pixelsPerTick = AppConstants.basePixelsPerSecond * scrollSpeed / 60.0
                let maxOffset = max(0, contentHeight - screenHeight + 80)
                print("[Queue] tick — offset=\(Int(contentOffset)) maxOffset=\(Int(maxOffset)) contentH=\(Int(contentHeight)) screenH=\(Int(screenHeight))")
                if contentOffset < maxOffset {
                    contentOffset += pixelsPerTick
                } else {
                    print("[Queue] finished script")
                    pause()
                    isFinished = true
                    onFinished?()
                    break
                }
            }
        }
    }

    private func startTimedElapsedTask() {
        timedElapsedTask?.cancel()
        timedElapsedTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                elapsedPlayTime += 1
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
        timedElapsedTask?.cancel()
    }
}
