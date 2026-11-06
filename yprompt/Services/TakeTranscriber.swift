//
//  TakeTranscriber.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import Foundation
import Speech
import os

private let log = Logger(subsystem: "com.giusscos.yprompt", category: "Takes")

/// A word heard in a take, with its time in the recording.
nonisolated struct SpokenWord: Hashable, Sendable, Codable {
    var text: String
    var start: Double
    var end: Double
}

/// What a take's sound says: the words with their times, and how loud it is over time.
nonisolated struct TakeAnalysis: Sendable, Codable {
    enum Speech: String, Sendable, Equatable, Codable {
        case recognized
        /// Speech recognition permission was declined or is restricted.
        case notAllowed
        /// No recognizer for the script's language, or recognition failed.
        case unavailable
    }

    static let envelopeInterval = 0.05

    var words: [SpokenWord]
    var speech: Speech
    /// Loudness in dB for every `envelopeInterval` seconds of the take.
    var envelope: [Float]

    /// Where the speaking starts and ends, with a little room either side.
    /// Nil when there's nothing worth cutting.
    func trimRange(duration: Double) -> ClosedRange<Double>? {
        guard let speech = speechRange() else { return nil }
        let start = max(0, speech.lowerBound - 0.3)
        let end = min(duration, speech.upperBound + 0.5)
        guard end - start >= 1, start > 0.1 || end < duration - 0.1 else { return nil }
        return start...end
    }

    private func speechRange() -> ClosedRange<Double>? {
        if let first = words.first, let last = words.last, last.end > first.start {
            return first.start...last.end
        }
        // No words: the loud part, measured against the room's own noise.
        guard envelope.count > 10 else { return nil }
        let noiseFloor = envelope.sorted()[envelope.count / 10]
        let threshold = noiseFloor + 12
        guard let first = envelope.firstIndex(where: { $0 > threshold }),
              let last = envelope.lastIndex(where: { $0 > threshold }),
              last > first else { return nil }
        return Double(first) * Self.envelopeInterval...Double(last + 1) * Self.envelopeInterval
    }
}

/// Listens to a finished take: finds the words and when each was said, on the device when it can.
nonisolated enum TakeTranscriber {
    static let sampleRate: Double = 16_000
    /// Apple's servers stop listening after about a minute, so longer takes go in pieces.
    private static let windowSeconds: Double = 50
    /// Longer takes still get trimmed, but no captions.
    private static let maxCaptionSeconds: Double = 20 * 60

    @MainActor
    static func analyze(url: URL, script: ScriptWords) async -> TakeAnalysis {
        let audio: (samples: [Float], envelope: [Float])
        do {
            audio = try await readAudio(url: url)
        } catch {
            log.error("Couldn't read the take's sound: \(String(describing: error), privacy: .public)")
            return TakeAnalysis(words: [], speech: .unavailable, envelope: [])
        }
        let samples = audio.samples
        guard !samples.isEmpty, Double(samples.count) / sampleRate <= maxCaptionSeconds else {
            return TakeAnalysis(words: [], speech: .unavailable, envelope: audio.envelope)
        }
        guard await SpeechWordTracker.requestAuthorization() else {
            return TakeAnalysis(words: [], speech: .notAllowed, envelope: audio.envelope)
        }
        guard let recognizer = SpeechWordTracker.recognizer(forScript: script.text) else {
            log.notice("No recognizer for this script's language")
            return TakeAnalysis(words: [], speech: .unavailable, envelope: audio.envelope)
        }
        // Right after launch the recognizer can report itself unavailable for a moment.
        for _ in 0..<25 where !recognizer.isAvailable {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard recognizer.isAvailable else {
            log.notice("Recognizer for \(recognizer.locale.identifier, privacy: .public) isn't available")
            return TakeAnalysis(words: [], speech: .unavailable, envelope: audio.envelope)
        }

        let contextual = SpeechWordTracker.contextualWords(for: script)
        var onDevice = recognizer.supportsOnDeviceRecognition
        var words: [SpokenWord] = []
        var failedWindows = 0
        let windows = windows(sampleCount: samples.count, envelope: audio.envelope)
        log.notice("Transcribing \(windows.count) piece(s) in \(recognizer.locale.identifier, privacy: .public), on device: \(onDevice)")

        for window in windows {
            guard !Task.isCancelled else { break }
            let offset = Double(window.lowerBound) / sampleRate
            var result = await recognize(samples[window], offset: offset, recognizer: recognizer,
                                         onDevice: onDevice, contextual: contextual)
            if case .failure = result, onDevice {
                // The on-device model may not be installed; Apple's servers can still do it.
                onDevice = false
                result = await recognize(samples[window], offset: offset, recognizer: recognizer,
                                         onDevice: false, contextual: contextual)
            }
            switch result {
            case .success(let heard): words += heard
            case .failure(let error):
                failedWindows += 1
                log.notice("Recognition failed: \(String(describing: error), privacy: .public)")
            }
        }
        let speech: TakeAnalysis.Speech = failedWindows == windows.count ? .unavailable : .recognized
        return TakeAnalysis(words: words, speech: speech, envelope: audio.envelope)
    }

    // MARK: - Sound

    /// The take's sound as 16 kHz mono samples, plus its loudness every 50 ms.
    @concurrent
    private static func readAudio(url: URL) async throws -> (samples: [Float], envelope: [Float]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return ([], []) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return ([], []) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return (samples, envelope(of: samples))
    }

    nonisolated private static func envelope(of samples: [Float]) -> [Float] {
        let hop = Int(sampleRate * TakeAnalysis.envelopeInterval)
        var result: [Float] = []
        result.reserveCapacity(samples.count / hop + 1)
        samples.withUnsafeBufferPointer { p in
            var index = 0
            while index < p.count {
                let end = min(index + hop, p.count)
                var sum: Float = 0
                for i in index..<end { sum += p[i] * p[i] }
                let rms = (sum / Float(end - index)).squareRoot()
                result.append(rms > 0 ? 20 * log10(rms) : -100)
                index = end
            }
        }
        return result
    }

    /// Pieces of at most `windowSeconds`, each cut at the quietest moment before its limit,
    /// so no word is split between two pieces.
    private static func windows(sampleCount: Int, envelope: [Float]) -> [Range<Int>] {
        let window = Int(windowSeconds * sampleRate)
        let hop = Int(sampleRate * TakeAnalysis.envelopeInterval)
        var ranges: [Range<Int>] = []
        var start = 0
        while sampleCount - start > window {
            let limit = start + window
            let lastSlot = min(limit / hop - 1, envelope.count - 1)
            let firstSlot = max(start / hop + 1, lastSlot - Int(5 / TakeAnalysis.envelopeInterval))
            var quietest = lastSlot
            if firstSlot <= lastSlot {
                for slot in firstSlot...lastSlot where envelope[slot] < envelope[quietest] { quietest = slot }
            }
            let cut = min(max(start + hop, quietest * hop + hop / 2), limit)
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<sampleCount)
        return ranges
    }

    // MARK: - Recognition

    private static func recognize(
        _ samples: ArraySlice<Float>,
        offset: Double,
        recognizer: SFSpeechRecognizer,
        onDevice: Bool,
        contextual: [String]
    ) async -> Result<[SpokenWord], Error> {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        request.contextualStrings = contextual
        request.addsPunctuation = false

        // Recognition normally answers well within the piece's own length.
        let limit = Double(samples.count) / sampleRate + 30
        var timeout: Task<Void, Never>?
        let result = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let task = recognizer.recognitionTask(with: request, resultHandler: makeHandler(offset: offset, once: once))
            append(samples, to: request)
            request.endAudio()
            timeout = Task {
                try? await Task.sleep(for: .seconds(limit))
                guard !Task.isCancelled else { return }
                task.cancel()
                once.resume(.failure(CocoaError(.userCancelled)))
            }
        }
        timeout?.cancel()
        return result
    }

    private static func append(_ samples: ArraySlice<Float>, to request: SFSpeechAudioBufferRecognitionRequest) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else { return }
        let chunk = Int(sampleRate)
        var index = samples.startIndex
        while index < samples.endIndex {
            let count = min(chunk, samples.endIndex - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            samples[index..<(index + count)].withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: count)
            }
            request.append(buffer)
            index += count
        }
    }

    /// Recognition calls back on its own queue, so this closure must not inherit the main actor.
    nonisolated private static func makeHandler(
        offset: Double,
        once: ResumeOnce
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let result, result.isFinal {
                let words = result.bestTranscription.segments.flatMap { segment in
                    spokenWords(segment.substring, start: offset + segment.timestamp, duration: segment.duration)
                }
                once.resume(.success(words))
            } else if let error {
                // A piece with nothing said in it isn't a failure.
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                    once.resume(.success([]))
                } else {
                    once.resume(.failure(error))
                }
            }
        }
    }

    /// A segment is normally one word; split the rare one that isn't, sharing its time.
    nonisolated private static func spokenWords(_ text: String, start: Double, duration: Double) -> [SpokenWord] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count > 1 else {
            return parts.map { SpokenWord(text: $0, start: start, end: start + duration) }
        }
        let share = duration / Double(parts.count)
        return parts.enumerated().map { index, part in
            SpokenWord(text: part, start: start + share * Double(index), end: start + share * Double(index + 1))
        }
    }
}

/// Resumes a continuation exactly once, from whichever callback comes first.
nonisolated private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<[SpokenWord], Error>, Never>?

    init(_ continuation: CheckedContinuation<Result<[SpokenWord], Error>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<[SpokenWord], Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: result)
    }
}
#endif
