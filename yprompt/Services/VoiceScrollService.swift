//
//  VoiceScrollService.swift
//  yprompt
//

#if !os(watchOS)
import AVFoundation

/// Listens to the microphone. Follows the script word by word through speech recognition;
/// when that isn't available (permission declined, unsupported language), it falls back to
/// loudness alone, so the script moves while the reader speaks.
@Observable @MainActor
final class VoiceScrollService {
    private(set) var currentPower: Float = -80
    var speechThreshold: Float = -30
    private(set) var isRunning: Bool = false
    private(set) var isSpeaking: Bool = false
    /// True while speech recognition is following the script.
    private(set) var isTrackingWords: Bool = false

    /// Latest recognized words, most recent last.
    @ObservationIgnored var onSpokenWords: (([String]) -> Void)? {
        didSet { tracker.onSpokenWords = onSpokenWords }
    }
    /// Set while the camera is capturing: it owns the audio session's mode and lifetime.
    @ObservationIgnored var sharesAudioSessionWithCamera = false

    var normalizedLevel: Float { Self.normalize(currentPower) }
    var normalizedThreshold: Float { Self.normalize(speechThreshold) }

    private let engine = AVAudioEngine()
    @ObservationIgnored private let tracker = SpeechWordTracker()
    @ObservationIgnored private var words: ScriptWords?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    // Asymmetric smoothing: fast attack so speech onset is detected quickly,
    // slow release so short silent gaps don't cut the scroll mid-word.
    private let attackFactor: Float = 0.35
    private let releaseFactor: Float = 0.07
    // Keep isSpeaking true for this long after power drops below threshold,
    // bridging natural pauses between words.
    private let hangDuration: TimeInterval = 0.4
    @ObservationIgnored private var lastSpeechDate: Date = .distantPast
    #if DEBUG
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    #endif

    init() {
        tracker.onUnavailable = { [weak self] in self?.isTrackingWords = false }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
    }

    // MARK: - Permission

    /// Asks for the microphone, then for speech recognition. Only the microphone is required.
    func requestPermission() async -> Bool {
        #if DEBUG
        if let demo = Self.demoArgument {
            if !demo.isEmpty { _ = await SpeechWordTracker.requestAuthorization() }
            return true
        }
        #endif
        let microphone: Bool
        #if os(iOS) || os(visionOS)
        if #available(iOS 17.0, visionOS 1.0, *) {
            microphone = await AVAudioApplication.requestRecordPermission()
        } else {
            microphone = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
        }
        #elseif os(macOS)
        microphone = await AVCaptureDevice.requestAccess(for: .audio)
        #else
        microphone = false
        #endif
        if microphone { _ = await SpeechWordTracker.requestAuthorization() }
        return microphone
    }

    // MARK: - Script

    /// The script to follow; nil means loudness alone. Takes effect at once if already listening.
    func prepareTracking(for words: ScriptWords?) {
        self.words = words
        if isRunning { startTracking() }
    }

    private func startTracking() {
        tracker.stop()
        isTrackingWords = false
        guard let words, !words.isEmpty else { return }
        isTrackingWords = tracker.start(words: words)
    }

    // MARK: - Engine control

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        #if DEBUG
        if startDemoIfRequested() { return true }
        #endif

        guard configureAudioSession(), installTap() else { return false }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            return false
        }

        isRunning = true
        startTracking()
        return true
    }

    func stop() {
        guard isRunning else { return }
        #if DEBUG
        demoTask?.cancel()
        demoTask = nil
        #endif
        tracker.stop()
        isTrackingWords = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        currentPower = -80
        isSpeaking = false
        lastSpeechDate = .distantPast

        #if os(iOS) || os(visionOS)
        if !sharesAudioSessionWithCamera {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    private func configureAudioSession() -> Bool {
        #if os(iOS) || os(visionOS)
        // The camera has already set up the session it records with.
        guard !sharesAudioSessionWithCamera else { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            // .voiceChat applies OS-level noise suppression and echo cancellation,
            // significantly improving speech detection over background noise.
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            return false
        }
        #endif
        return true
    }

    private func installTap() -> Bool {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // No usable microphone at the moment (e.g. mid route change).
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        let power: @Sendable (Float) -> Void = { [weak self] power in
            Task { @MainActor [weak self] in self?.apply(power: power) }
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format,
                             block: Self.makeTap(sink: tracker.sink, onPower: power))
        return true
    }

    /// Runs on the audio thread, so it must not inherit the main actor.
    nonisolated private static func makeTap(
        sink: SpeechAudioSink,
        onPower: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            sink.append(buffer)
            onPower(calculatePower(buffer: buffer))
        }
    }

    private func apply(power: Float) {
        let factor = power > currentPower ? attackFactor : releaseFactor
        currentPower = currentPower * (1 - factor) + power * factor
        if currentPower > speechThreshold {
            lastSpeechDate = Date()
            if !isSpeaking { isSpeaking = true }
        } else if isSpeaking && Date().timeIntervalSince(lastSpeechDate) > hangDuration {
            isSpeaking = false
        }
    }

    /// The system stops the engine when the audio route or session changes,
    /// for example when the camera starts capturing.
    private func restartAfterConfigurationChange() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        guard configureAudioSession(), installTap() else { return }
        try? engine.start()
        tracker.restart()
    }

    // MARK: - Normalization (dB <-> 0…1, range: -60…0 dB)

    nonisolated static func normalize(_ dB: Float) -> Float {
        max(0, min(1, (dB + 60) / 60))
    }

    nonisolated static func denormalize(_ normalized: Float) -> Float {
        normalized * 60 - 60
    }

    // MARK: - RMS power

    nonisolated private static func calculatePower(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return -80 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return -80 }
        let sumOfSquares = (0..<frameLength).reduce(Float(0)) { $0 + channelData[$1] * channelData[$1] }
        let rms = sqrt(sumOfSquares / Float(frameLength))
        guard rms > 0 else { return -80 }
        return 20 * log10(rms)
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}

// MARK: - Debug speech without a microphone

#if DEBUG
extension VoiceScrollService {
    /// Launch with `-ypDemoVoice` to read the script aloud in simulation, or with
    /// `-ypDemoVoice <audio file>` to send a recording through real speech recognition.
    fileprivate static var demoArgument: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-ypDemoVoice") else { return nil }
        let next = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        return next.hasPrefix("-") ? "" : next
    }

    fileprivate func startDemoIfRequested() -> Bool {
        guard let path = Self.demoArgument else { return false }
        isRunning = true
        if path.isEmpty {
            demoTask = Task { [weak self] in await self?.runSimulatedSpeech() }
        } else {
            startTracking()
            demoTask = Task { [weak self] in await self?.playRecording(path: path) }
        }
        return true
    }

    /// Reads at a natural pace with pauses and some misheard words, as recognition would report them.
    private func runSimulatedSpeech() async {
        guard let keys = words?.words.map(\.key) else { return }
        isTrackingWords = true
        var heard: [String] = []
        for (index, key) in keys.enumerated() {
            guard !Task.isCancelled else { return }
            if index > 0, index % 14 == 0 {
                isSpeaking = false
                currentPower = -55
                try? await Task.sleep(for: .milliseconds(1100))
            }
            isSpeaking = true
            currentPower = -18
            heard.append(index % 11 == 10 ? "zzz" : key)
            onSpokenWords?(Array(heard.suffix(12)))
            try? await Task.sleep(for: .milliseconds(360))
        }
        isSpeaking = false
    }

    private func playRecording(path: String) async {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return }
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        while !Task.isCancelled, file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                  (try? file.read(into: buffer, frameCount: chunk)) != nil else { return }
            tracker.sink.append(buffer)
            currentPower = Self.demoPower(of: buffer)
            isSpeaking = currentPower > speechThreshold
            try? await Task.sleep(for: .milliseconds(100))
        }
        isSpeaking = false
    }

    private static func demoPower(of buffer: AVAudioPCMBuffer) -> Float { calculatePower(buffer: buffer) }
}
#endif
#endif
