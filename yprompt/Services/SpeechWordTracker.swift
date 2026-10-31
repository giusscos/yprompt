//
//  SpeechWordTracker.swift
//  yprompt
//

#if !os(watchOS)
import AVFoundation
import NaturalLanguage
import Speech
import os

private let log = Logger(subsystem: "com.giusscos.yprompt", category: "Speech")

/// Passes microphone buffers from the audio thread to the current recognition request.
nonisolated final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func connect(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { self.request = request }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }
}

/// Turns speech into recognized words for the script's language, on the device when it can.
/// Recognition tasks end on their own, so a new one starts whenever the last one finishes.
@MainActor
final class SpeechWordTracker {
    let sink = SpeechAudioSink()

    /// Latest recognized words, most recent last, already normalized for matching.
    var onSpokenWords: (([String]) -> Void)?
    /// Recognition can't run; the caller falls back to following loudness alone.
    var onUnavailable: (() -> Void)?

    private(set) var isActive = false

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var contextualWords: [String] = []
    private var prefersOnDevice = true
    private var taskStart = Date.distantPast
    private var taskHeardWords = false
    private var quickFailures = 0

    /// Recognition requests that fail right away this many times in a row aren't going to work.
    private static let maxQuickFailures = 3

    static func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status == .authorized }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Returns false when no recognizer can handle this script's language.
    func start(words: ScriptWords) -> Bool {
        stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = Self.recognizer(forScript: words.text),
              recognizer.isAvailable else {
            log.info("Word tracking unavailable")
            return false
        }
        self.recognizer = recognizer
        // Names and unusual words are the ones recognition most often gets wrong.
        contextualWords = Array(
            Set(words.words.map(\.text).filter { $0.count >= 6 }).sorted { $0.count > $1.count }.prefix(100)
        )
        prefersOnDevice = recognizer.supportsOnDeviceRecognition
        quickFailures = 0
        isActive = true
        log.info("Tracking words in \(recognizer.locale.identifier, privacy: .public), on device: \(self.prefersOnDevice, privacy: .public)")
        startTask()
        return true
    }

    func stop() {
        isActive = false
        sink.connect(nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Starts a fresh request, e.g. after the microphone's audio format changed.
    func restart() {
        guard isActive else { return }
        endCurrentTask()
        startTask()
    }

    // MARK: - Tasks

    private func startTask() {
        guard isActive, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextualWords
        request.requiresOnDeviceRecognition = prefersOnDevice
        request.addsPunctuation = false
        self.request = request
        taskStart = Date()
        taskHeardWords = false
        sink.connect(request)
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(for: self))
    }

    private func endCurrentTask() {
        sink.connect(nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Recognition calls back on its own queue, so this closure must not inherit the main actor.
    nonisolated private static func makeHandler(
        for tracker: SpeechWordTracker
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak tracker] result, error in
            let segments = result?.bestTranscription.segments.suffix(12).map(\.substring) ?? []
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            let description = error.map { String(describing: $0) }
            Task { @MainActor in
                tracker?.handle(segments: segments, isFinal: isFinal, failed: failed, errorDescription: description)
            }
        }
    }

    private func handle(segments: [String], isFinal: Bool, failed: Bool, errorDescription: String?) {
        guard isActive else { return }
        if !segments.isEmpty {
            let spoken = ScriptWords.spokenKeys(from: segments)
            if !spoken.isEmpty {
                taskHeardWords = true
                quickFailures = 0
                onSpokenWords?(spoken)
            }
        }
        guard isFinal || failed else { return }
        if let errorDescription {
            log.info("Recognition ended: \(errorDescription, privacy: .public)")
        }

        // Silence or the time limit ending a task is normal; failing straight away isn't.
        if failed, !taskHeardWords, Date().timeIntervalSince(taskStart) < 2 {
            if prefersOnDevice {
                // The on-device model may not be installed; try Apple's servers instead.
                prefersOnDevice = false
            } else {
                quickFailures += 1
                if quickFailures >= Self.maxQuickFailures {
                    stop()
                    onUnavailable?()
                    return
                }
            }
        }
        endCurrentTask()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.startTask()
        }
    }

    // MARK: - Language

    /// Picks a recognizer for the language the script is written in, using the user's own
    /// region when it applies. Short scripts lean towards the device language.
    private static func recognizer(forScript text: String) -> SFSpeechRecognizer? {
        let current = Locale.current
        let currentLanguage = current.language.languageCode?.identifier

        let detector = NLLanguageRecognizer()
        if let currentLanguage {
            detector.languageHints = [NLLanguage(currentLanguage): 0.6]
        }
        detector.processString(String(text.prefix(2000)))
        let language = detector.dominantLanguage?.rawValue ?? currentLanguage

        let supported = SFSpeechRecognizer.supportedLocales()
        let matching = supported
            .filter { $0.language.languageCode?.identifier == language }
            .sorted { $0.identifier < $1.identifier }
        let chosen = matching.first { $0.region == current.region }
            ?? matching.first { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            ?? matching.first
        return chosen.flatMap(SFSpeechRecognizer.init(locale:)) ?? SFSpeechRecognizer()
    }
}
#endif
