//
//  RecordingComposer.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import CoreImage
import CoreText

/// A recording put together for AVFoundation: its pieces one after another, each video piece
/// turned upright, rotated as chosen, and filling a frame the size of the first piece.
struct ComposedRecording {
    struct Segment {
        let trackID: CMPersistentTrackID
        let timeRange: CMTimeRange
        /// From the source frame to the output frame, in video coordinates (origin top left).
        let transform: CGAffineTransform
    }

    let composition: AVMutableComposition
    let segments: [Segment]
    let renderSize: CGSize
    let frameDuration: CMTime
    let isHEVC: Bool
    let isVideo: Bool

    /// For the preview: the built-in compositor places each piece. Captions and the mark are
    /// drawn over the player by the same renderer the export uses.
    func previewComposition() -> AVVideoComposition? {
        guard isVideo, !segments.isEmpty else { return nil }
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = frameDuration
        composition.instructions = instructionRanges().map { segment, range in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            if let track = self.composition.track(withTrackID: segment.trackID) {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(segment.transform, at: range.start)
                instruction.layerInstructions = [layer]
            }
            return instruction
        }
        return composition
    }

    /// For saving: the same layout, with the captions and the mark drawn into every frame.
    func exportComposition(captions: CaptionRenderer?, mark: Watermark?) -> AVVideoComposition? {
        guard isVideo, !segments.isEmpty else { return nil }
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = RecordingCompositor.self
        composition.renderSize = renderSize
        composition.frameDuration = frameDuration
        composition.instructions = instructionRanges().map { segment, range in
            RecordingInstruction(timeRange: range, trackID: segment.trackID, transform: segment.transform,
                                 renderSize: renderSize, captions: captions, mark: mark)
        }
        return composition
    }

    /// Instructions must cover the whole composition with no gaps. A piece's video can end a
    /// frame before its sound, so each runs until the next begins, and the last to the end.
    private func instructionRanges() -> [(Segment, CMTimeRange)] {
        segments.enumerated().map { index, segment in
            let start = index == 0 ? .zero : segment.timeRange.start
            let end = index + 1 < segments.count
                ? segments[index + 1].timeRange.start
                : CMTimeMaximum(segment.timeRange.end, composition.duration)
            return (segment, CMTimeRange(start: start, end: end))
        }
    }
}

enum RecordingComposer {
    private struct Source {
        /// Held so the tracks stay usable: a track only keeps a weak reference to its asset.
        let asset: AVURLAsset
        let video: AVAssetTrack?
        let audio: AVAssetTrack?
        /// Each track's own extent; the video can end a frame before the sound.
        let videoRange: CMTimeRange?
        let audioRange: CMTimeRange?
        let duration: CMTime
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let frameRate: Float
        let isHEVC: Bool
    }

    static func compose(_ recording: Recording, editList: EditList) async throws -> ComposedRecording {
        let isVideo = recording.kind == .video
        let composition = AVMutableComposition()
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        // Two video tracks taking turns, so each piece keeps its own orientation.
        let videoTracks = isVideo
            ? (0..<2).compactMap { _ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
            : []

        var sources: [String: Source] = [:]
        var placed: [(track: CMPersistentTrackID, range: CMTimeRange, source: Source)] = []
        var cursor = CMTime.zero
        for (index, segment) in editList.segments.enumerated() {
            let source: Source
            if let cached = sources[segment.file] {
                source = cached
            } else {
                source = try await load(recording.folder.appendingPathComponent(segment.file))
                sources[segment.file] = source
            }
            let start = CMTime(seconds: segment.sourceStart, preferredTimescale: 600)
            let end = CMTimeMinimum(CMTime(seconds: segment.sourceEnd, preferredTimescale: 600), source.duration)
            guard end > start else { continue }
            let range = CMTimeRange(start: start, end: end)
            var length = CMTime.zero
            if let audio = source.audio, let audioRange = source.audioRange {
                let clipped = range.intersection(audioRange)
                if clipped.duration > .zero {
                    try audioTrack?.insertTimeRange(clipped, of: audio, at: cursor)
                    length = CMTimeMaximum(length, clipped.duration)
                }
            }
            if let video = source.video, let videoRange = source.videoRange, !videoTracks.isEmpty {
                let clipped = range.intersection(videoRange)
                if clipped.duration > .zero {
                    let track = videoTracks[index % videoTracks.count]
                    try track.insertTimeRange(clipped, of: video, at: cursor)
                    placed.append((track.trackID, CMTimeRange(start: cursor, duration: clipped.duration), source))
                    length = CMTimeMaximum(length, clipped.duration)
                }
            }
            cursor = cursor + length
        }
        // A take without sound leaves the audio track empty, and exporting a composition with
        // an empty track stops with "Operation Stopped" (-11838).
        if let audioTrack, audioTrack.segments.isEmpty { composition.removeTrack(audioTrack) }

        let first = placed.first?.source
        let upright = first.map { uprightSize($0.naturalSize, $0.preferredTransform) } ?? .zero
        let turns = ((recording.quarterTurns % 4) + 4) % 4
        let turned = turns.isMultiple(of: 2) ? upright : CGSize(width: upright.height, height: upright.width)
        // Video encoders want even sizes.
        let renderSize = CGSize(width: (turned.width / 2).rounded() * 2, height: (turned.height / 2).rounded() * 2)
        let segments = placed.map { track, range, source in
            ComposedRecording.Segment(trackID: track, timeRange: range,
                                      transform: layout(source, quarterTurns: turns, in: renderSize))
        }
        let fps = placed.map(\.source.frameRate).max() ?? 30
        return ComposedRecording(
            composition: composition, segments: segments, renderSize: renderSize,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps > 0 ? fps.rounded() : 30)),
            isHEVC: sources.values.contains(where: \.isHEVC), isVideo: isVideo && !segments.isEmpty)
    }

    private static func load(_ url: URL) async throws -> Source {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let audioRange = try await audio?.load(.timeRange)
        guard let video else {
            return Source(asset: asset, video: nil, audio: audio, videoRange: nil, audioRange: audioRange, duration: duration,
                          naturalSize: .zero, preferredTransform: .identity, frameRate: 0, isHEVC: false)
        }
        let (size, transform, rate, formats, videoRange) = try await video.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .timeRange)
        return Source(asset: asset, video: video, audio: audio, videoRange: videoRange, audioRange: audioRange,
                      duration: duration, naturalSize: size, preferredTransform: transform,
                      frameRate: rate, isHEVC: formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC })
    }

    private static func uprightSize(_ size: CGSize, _ transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Source frame → upright → turned clockwise → scaled to fill the frame, centered.
    private static func layout(_ source: Source, quarterTurns: Int, in renderSize: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: source.naturalSize).applying(source.preferredTransform)
        var transform = source.preferredTransform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let upright = CGSize(width: abs(rect.width), height: abs(rect.height))
        transform = transform.concatenating(clockwise(quarterTurns: quarterTurns, size: upright))
        let turned = quarterTurns.isMultiple(of: 2) ? upright : CGSize(width: upright.height, height: upright.width)
        guard turned.width > 0, turned.height > 0 else { return transform }
        let scale = max(renderSize.width / turned.width, renderSize.height / turned.height)
        return transform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (renderSize.width - turned.width * scale) / 2,
                                             y: (renderSize.height - turned.height * scale) / 2))
    }

    /// Turns a picture of `size` clockwise, in video coordinates (origin top left), keeping it
    /// in positive coordinates.
    nonisolated static func clockwise(quarterTurns: Int, size: CGSize) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        var size = size
        for _ in 0..<((quarterTurns % 4 + 4) % 4) {
            transform = transform.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0))
            size = CGSize(width: size.height, height: size.width)
        }
        return transform
    }
}

// MARK: - Drawing frames for export

/// One stretch of the export: which track to draw, how to place it, and what goes on top.
nonisolated final class RecordingInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let renderSize: CGSize
    let captions: CaptionRenderer?
    let mark: Watermark?

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform,
         renderSize: CGSize, captions: CaptionRenderer?, mark: Watermark?) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.transform = transform
        self.renderSize = renderSize
        self.captions = captions
        self.mark = mark
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Draws each saved frame: the piece placed upright, then the captions and the mark.
nonisolated final class RecordingCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? RecordingInstruction,
              let source = request.sourceFrame(byTrackID: instruction.trackID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue))
            return
        }
        let size = instruction.renderSize
        let frame = CGRect(origin: .zero, size: size)
        let sourceImage = CIImage(cvPixelBuffer: source)
        // The transform works with the origin at the top left; Core Image's is at the bottom left.
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceImage.extent.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        var image = sourceImage.transformed(by: flipIn.concatenating(instruction.transform).concatenating(flipOut))
            .composited(over: CIImage(color: .black).cropped(to: frame))
        if let caption = instruction.captions?.image(at: request.compositionTime.seconds) {
            image = CIImage(cgImage: caption.image)
                .transformed(by: CGAffineTransform(translationX: caption.origin.x, y: caption.origin.y))
                .composited(over: image)
        }
        if let mark = instruction.mark {
            image = CIImage(cgImage: mark.image)
                .transformed(by: CGAffineTransform(translationX: mark.origin.x, y: mark.origin.y))
                .composited(over: image)
        }
        Self.context.render(image.cropped(to: frame), to: output, bounds: frame, colorSpace: Self.colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}

// MARK: - The mark

/// "Made with yPrompt" in the top-left corner of videos saved without Pro.
/// Social apps put their own buttons along the bottom and right edges.
nonisolated struct Watermark: @unchecked Sendable {
    let image: CGImage
    /// Bottom-left corner of the image in the frame (origin bottom left).
    let origin: CGPoint

    static func make(for size: CGSize) -> Watermark? {
        let shortSide = min(size.width, size.height)
        guard shortSide > 0 else { return nil }
        let fontSize = max(10, (shortSide * 0.032).rounded())
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.95),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(localized: "Made with yPrompt"),
                                                                       attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let padding = (fontSize * 0.6).rounded()
        let width = Int((textWidth + padding * 2).rounded(.up))
        let height = Int((ascent + descent + padding * 1.2).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let pill = CGRect(x: 0, y: 0, width: width, height: height)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: CGFloat(height) / 2, cornerHeight: CGFloat(height) / 2, transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 0.45))
        context.fillPath()
        context.textPosition = CGPoint(x: padding, y: (CGFloat(height) - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        let margin = (shortSide * 0.04).rounded()
        return Watermark(image: image, origin: CGPoint(x: margin, y: size.height - margin - CGFloat(height)))
    }
}
#endif
