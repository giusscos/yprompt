//
//  VoiceScrollService.swift
//  yprompt
//

#if !os(watchOS)
import AVFoundation

@Observable @MainActor
final class VoiceScrollService {
    private(set) var currentPower: Float = -80
    var speechThreshold: Float = -30
    private(set) var isRunning: Bool = false
    private(set) var isSpeaking: Bool = false

    var normalizedLevel: Float { Self.normalize(currentPower) }
    var normalizedThreshold: Float { Self.normalize(speechThreshold) }

    private let engine = AVAudioEngine()
    // Asymmetric smoothing: fast attack so speech onset is detected quickly,
    // slow release so short silent gaps don't cut the scroll mid-word.
    private let attackFactor: Float = 0.35
    private let releaseFactor: Float = 0.07
    // Keep isSpeaking true for this long after power drops below threshold,
    // bridging natural pauses between words.
    private let hangDuration: TimeInterval = 0.4
    @ObservationIgnored private var lastSpeechDate: Date = .distantPast

    // MARK: - Permission

    func requestPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
        }
        #elseif os(macOS)
        return await AVCaptureDevice.requestAccess(for: .audio)
        #else
        return false
        #endif
    }

    // MARK: - Engine control

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        #if os(iOS)
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

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let power = Self.calculatePower(buffer: buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let factor = power > self.currentPower ? self.attackFactor : self.releaseFactor
                self.currentPower = self.currentPower * (1 - factor) + power * factor
                if self.currentPower > self.speechThreshold {
                    self.lastSpeechDate = Date()
                    if !self.isSpeaking { self.isSpeaking = true }
                } else if self.isSpeaking && Date().timeIntervalSince(self.lastSpeechDate) > self.hangDuration {
                    self.isSpeaking = false
                }
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return false
        }

        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        currentPower = -80
        isSpeaking = false
        lastSpeechDate = .distantPast

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Normalization (dB <-> 0…1, range: -60…0 dB)

    static func normalize(_ dB: Float) -> Float {
        max(0, min(1, (dB + 60) / 60))
    }

    static func denormalize(_ normalized: Float) -> Float {
        normalized * 60 - 60
    }

    // MARK: - RMS power

    private static func calculatePower(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return -80 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return -80 }
        let sumOfSquares = (0..<frameLength).reduce(Float(0)) { $0 + channelData[$1] * channelData[$1] }
        let rms = sqrt(sumOfSquares / Float(frameLength))
        guard rms > 0 else { return -80 }
        return 20 * log10(rms)
    }

    deinit {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
#endif
