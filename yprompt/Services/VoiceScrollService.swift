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

    var isSpeaking: Bool { currentPower > speechThreshold }
    var normalizedLevel: Float { Self.normalize(currentPower) }
    var normalizedThreshold: Float { Self.normalize(speechThreshold) }

    private let engine = AVAudioEngine()
    private let smoothingFactor: Float = 0.15

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
            try session.setCategory(.playAndRecord, mode: .measurement,
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
                self.currentPower = self.currentPower * (1 - self.smoothingFactor) + power * self.smoothingFactor
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
