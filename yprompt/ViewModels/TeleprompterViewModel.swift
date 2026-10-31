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

    // The script split into words: sets the speed scale in every style.
    private(set) var scriptWords: ScriptWords?
    // True while the reading position is measured in words (lyrics style) instead of pixels.
    private(set) var isWordMode: Bool = false
    // Position in words: 12.4 is 40% through word 12. Changes every frame, so the word view reads it from its own timeline.
    @ObservationIgnored private(set) var wordPosition: Double = 0
    // Whole word reached; changes a few times a second, so panels can observe it.
    private(set) var wordIndex: Int = 0
    // Reading position to restore once plain scrolling text has been measured.
    @ObservationIgnored private var pendingClassicProgress: Double?

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
            if usesWordClock { return remainingWordTime }
            let maxOffset = max(0, Double(contentHeight - screenHeight) + 80)
            let remaining = maxOffset - Double(contentOffset)
            return max(0, remaining / pixelsPerSecond(contentLength: contentHeight, speed: max(scrollSpeed, 0.01)))
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
    // Distance "read" since the text stopped moving: the last screenful still has to be read.
    @ObservationIgnored private var lastScreenRead: CGFloat = 0
    #if !os(watchOS)
    @ObservationIgnored private var aligner: WordAligner?
    @ObservationIgnored private var lastHeardDate: Date?
    @ObservationIgnored private var speakingRate = AppConstants.wordsPerSecond
    #endif

    init() {
        #if !os(watchOS)
        voiceScrollService.onSpokenWords = { [weak self] in self?.handleSpoken($0) }
        #endif
    }

    // MARK: - Script

    /// Sets the script being read. Scripts that can't be laid out word by word keep loudness-based voice.
    func load(words: ScriptWords) {
        scriptWords = words
        #if !os(watchOS)
        let trackable = !words.isEmpty && !words.isRightToLeft
        aligner = trackable ? WordAligner(words: words) : nil
        lastHeardDate = nil
        voiceScrollService.prepareTracking(for: trackable ? words : nil)
        #endif
        setWordPosition(0)
    }

    func setWordMode(_ enabled: Bool) {
        guard enabled != isWordMode else { return }
        let current = progress
        isWordMode = enabled
        if enabled {
            setWordPosition(current * Double(scriptWords?.count ?? 0))
        } else {
            pendingClassicProgress = current
        }
    }

    private var usesWordClock: Bool { isWordMode && !isNotchMode }

    /// Coming back from lyrics style: same place in the script, once the text has been measured.
    func restoreClassicPositionIfNeeded() {
        guard let progress = pendingClassicProgress, contentHeight > 0 else { return }
        pendingClassicProgress = nil
        contentOffset = max(0, contentHeight - screenHeight + 80) * CGFloat(progress)
    }

    // MARK: - Playback

    func play() {
        guard !isPlaying else { return }
        if isFinished { restartFromTop() }
        // Auto-compute speed so the script finishes in the requested duration (floating mode only)
        if !usesWordClock, let duration = timedDuration, duration > 0, contentHeight > screenHeight {
            let maxOffset = max(0, Double(contentHeight - screenHeight) + 80)
            let needed = maxOffset / (pixelsPerSecond(contentLength: contentHeight, speed: 1) * duration)
            scrollSpeed = min(AppConstants.maxScrollSpeed, needed)
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
        setWordPosition(0)
        syncAlignerToPosition()
        withAnimation(.easeOut(duration: 0.4)) { contentOffset = 0 }
        showControls = true
        hideControlsTask?.cancel()
        resetPublisher.send()
    }

    /// Pressing play on a finished script starts it again.
    private func restartFromTop() {
        isFinished = false
        contentOffset = 0
        setWordPosition(0)
        syncAlignerToPosition()
    }

    func prepareForNext(customization: TextCustomization) {
        print("[Queue] prepareForNext — resetting contentHeight from \(contentHeight) → 0")
        isFinished = false
        contentOffset = 0
        contentHeight = 0
        pendingAutoPlay = false
        setWordPosition(0)
        syncAlignerToPosition()
        scrollSpeed = customization.scrollSpeed
        transparency = customization.transparency
    }

    func resetForNext() {
        isFinished = false
        contentOffset = 0
        contentHeight = 0
        notchProgress = 0
        pendingAutoPlay = false
        setWordPosition(0)
        syncAlignerToPosition()
    }

    // MARK: - Progress

    var progress: Double {
        guard !isNotchMode else { return notchProgress }
        if isWordMode {
            guard let count = scriptWords?.count, count > 0 else { return 0 }
            return min(1, Double(wordIndex) / Double(count))
        }
        let maxOffset = max(1, contentHeight - screenHeight + 80)
        return min(1.0, Double(contentOffset) / Double(maxOffset))
    }

    func seek(to fraction: Double) {
        if isNotchMode {
            notchSeekRequest.send(fraction)
            return
        }
        if isWordMode {
            moveWordPosition(toProgress: fraction)
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
        if isWordMode {
            moveWordPosition(toProgress: cue.position)
            return
        }
        let maxOffset = max(0, contentHeight - screenHeight + 80)
        withAnimation(.easeOut(duration: 0.3)) {
            contentOffset = maxOffset * CGFloat(cue.position)
        }
    }

    // MARK: - Tap to Advance

    func tapAdvance() {
        if usesWordClock, let words = scriptWords {
            setWordPosition(Double(words.nextPhraseStart(after: wordIndex)))
            syncAlignerToPosition()
            return
        }
        let advance = screenHeight * 0.3
        let maxOffset = max(0, contentHeight - screenHeight + 80)
        withAnimation(.easeInOut(duration: 0.3)) {
            contentOffset = min(contentOffset + advance, maxOffset)
        }
    }

    func tapReverse() {
        if usesWordClock, let words = scriptWords {
            setWordPosition(Double(words.previousPhraseStart(before: wordIndex)))
            syncAlignerToPosition()
            return
        }
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
                syncAlignerToPosition()
                if isPlaying {
                    voiceScrollService.start()
                } else {
                    play()
                }
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
                if usesWordClock {
                    let step = AppConstants.wordsPerSecond * max(scrollSpeed, 1.0) * 2 / 60.0
                    setWordPosition(wordPosition + (direction == .forward ? step : -step))
                    syncAlignerToPosition()
                    continue
                }
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
            let clock = ContinuousClock()
            var lastTick = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_666_667)
                guard !Task.isCancelled else { break }
                let now = clock.now
                let elapsed = lastTick.duration(to: now)
                lastTick = now
                let dt = min(0.1, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)

                if usesWordClock {
                    if advanceWords(dt: dt) { finishReading(); break }
                    continue
                }

                #if !os(watchOS)
                // In voice scroll mode, only advance while the user is speaking
                if voiceScrollEnabled && !voiceScrollService.isSpeaking { continue }
                #endif

                // Notch mode scrolls horizontally via its own timer; skip the vertical task.
                guard !isNotchMode, contentHeight > 0 else {
                    if !isNotchMode { print("[Queue] scroll tick skipped — contentHeight=0 (waiting for layout)") }
                    continue
                }

                let maxOffset = max(0, contentHeight - screenHeight + 80)
                let step = CGFloat(pixelsPerSecond(contentLength: contentHeight, speed: scrollSpeed) * dt)
                if contentOffset < maxOffset {
                    contentOffset += step
                    lastScreenRead = 0
                } else {
                    // Timed mode ends on the clock; otherwise wait for the text left on screen to be read.
                    lastScreenRead += step
                    let leftOnScreen = min(contentHeight, screenHeight - 80)
                    if timedDuration != nil || lastScreenRead >= leftOnScreen {
                        print("[Queue] finished script")
                        lastScreenRead = 0
                        finishReading()
                        break
                    }
                }
            }
        }
    }

    private func finishReading() {
        pause()
        isFinished = true
        onFinished?()
    }

    // MARK: - Reading speed

    /// Pixels per second that read `contentLength` of text at `speed` × a natural speaking pace,
    /// whatever the font size or window width.
    func pixelsPerSecond(contentLength: CGFloat, speed: Double) -> Double {
        guard let count = scriptWords?.count, count > 0, contentLength > 0 else {
            return Double(AppConstants.basePixelsPerSecond) * speed
        }
        let secondsAtNormalSpeed = Double(count) / AppConstants.wordsPerSecond
        return Double(contentLength) / secondsAtNormalSpeed * speed
    }

    // MARK: - Word position

    private func setWordPosition(_ position: Double) {
        let count = scriptWords?.count ?? 0
        let clamped = min(max(0, position), Double(count))
        wordPosition = clamped
        let index = Int(clamped)
        if index != wordIndex { wordIndex = index }
    }

    private func moveWordPosition(toProgress fraction: Double) {
        setWordPosition(fraction * Double(scriptWords?.count ?? 0))
        syncAlignerToPosition()
    }

    private func syncAlignerToPosition() {
        #if !os(watchOS)
        aligner?.seek(to: wordIndex - 1)
        lastHeardDate = nil
        #endif
    }

    private var weightPerSecond: Double {
        guard let words = scriptWords, !words.isEmpty else { return 1 }
        if let duration = timedDuration, duration > 0 { return words.totalWeight / duration }
        return words.weightPerSecondAtNormalSpeed * max(scrollSpeed, 0.01)
    }

    private var remainingWordTime: TimeInterval {
        guard let words = scriptWords, !words.isEmpty else { return 0 }
        var remaining = 0.0
        for index in wordIndex..<words.count { remaining += words.words[index].weight }
        if wordIndex < words.count {
            remaining -= (wordPosition - Double(wordIndex)) * words.words[wordIndex].weight
        }
        return max(0, remaining / weightPerSecond)
    }

    /// Moves the reading position forward by one frame. Returns true at the end of the script.
    private func advanceWords(dt: Double) -> Bool {
        guard let words = scriptWords, !words.isEmpty else { return false }

        #if !os(watchOS)
        if voiceScrollEnabled {
            if voiceScrollService.isTrackingWords { return followVoice(dt: dt, count: words.count) }
            if !voiceScrollService.isSpeaking { return false }
        }
        #endif

        var budget = weightPerSecond * dt
        var position = wordPosition
        while budget > 0, position < Double(words.count) {
            let index = Int(position)
            let weight = words.words[index].weight
            let left = (1 - (position - Double(index))) * weight
            if budget >= left {
                position = Double(index + 1)
                budget -= left
            } else {
                position += budget / weight
                budget = 0
            }
        }
        setWordPosition(position)
        return position >= Double(words.count)
    }

    // MARK: - Following speech

    #if !os(watchOS)
    /// Share of the script heard so far, for views that don't read word by word (the Mac notch).
    var voiceTrackedFraction: Double? {
        guard voiceScrollService.isTrackingWords, let aligner, let count = scriptWords?.count, count > 0 else { return nil }
        return Double(aligner.position + 1) / Double(count)
    }

    private func handleSpoken(_ spoken: [String]) {
        guard var aligner else { return }
        let before = aligner.position
        guard aligner.update(spoken: spoken) else { return }
        self.aligner = aligner

        let now = Date()
        let advanced = aligner.position - before
        if (1...6).contains(advanced), let lastHeardDate {
            let seconds = now.timeIntervalSince(lastHeardDate)
            if seconds > 0.05 {
                speakingRate = speakingRate * 0.8 + min(5, Double(advanced) / seconds) * 0.2
            }
        }
        lastHeardDate = now
    }

    /// Recognition reports words a moment after they're said, so while the reader is still
    /// speaking the highlight runs slightly ahead of the last word heard to stay with the voice.
    private func followVoice(dt: Double, count: Int) -> Bool {
        guard let aligner else { return false }
        let now = Date()
        var target = Double(aligner.position + 1)
        if voiceScrollService.isSpeaking, let lastHeardDate {
            target += min(1.5, speakingRate * now.timeIntervalSince(lastHeardDate))
        }
        target = min(target, Double(count))

        let gap = target - wordPosition
        // Small negative gaps are the prediction catching up, not the reader going back.
        if gap > 0 || gap < -2.5 {
            setWordPosition(wordPosition + gap * (1 - exp(-dt * 9)))
        }

        let heardLastWord = aligner.position >= count - 1
        let stoppedNearEnd = aligner.position >= count - 3 && !voiceScrollService.isSpeaking
            && now.timeIntervalSince(lastHeardDate ?? .distantPast) > 2
        if heardLastWord && wordPosition >= Double(count) - 0.05 { return true }
        if stoppedNearEnd {
            setWordPosition(Double(count))
            return true
        }
        return false
    }
    #endif

    // MARK: - Timers

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
