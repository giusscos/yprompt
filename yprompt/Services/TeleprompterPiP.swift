//
//  TeleprompterPiP.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import Combine
import AVKit
import CoreText
import SwiftUI
import UIKit

/// The script in a Picture in Picture window, over any other app: read while recording in
/// the Camera app, Instagram or TikTok, or during a FaceTime or Zoom call.
///
/// Picture in Picture shows video, so the script is drawn into video frames, about 30 a
/// second, following the reading screen's scroll position. The window's play and skip
/// buttons control the scrolling.
@MainActor
final class TeleprompterPiP: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    let displayLayer = AVSampleBufferDisplayLayer()

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var viewModel: TeleprompterViewModel?
    private var layout: PiPTextLayout?
    private var timer: Timer?
    private var pool: CVPixelBufferPool?

    /// Landscape, so a line of the script fits across; the window can be resized.
    private let frameSize = CGSize(width: 960, height: 540)

    // MARK: Setup

    /// Ties the window to the reading screen's script and scrolling.
    /// `autoStart`: swiping home while reading floats the script, like a video does.
    func configure(viewModel: TeleprompterViewModel, text: String, autoStart: Bool) {
        self.viewModel = viewModel
        layout = PiPTextLayout(text: text, width: frameSize.width)
        displayLayer.videoGravity = .resizeAspect
        if controller == nil, Self.isSupported {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                    playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
                let possible = controller.isPictureInPicturePossible
                Task { @MainActor in self?.isPossible = possible }
            }
            self.controller = controller
        }
        setAutoStart(autoStart)
        startRendering()
    }

    /// Pro only, like the button; follows a purchase made while reading.
    func setAutoStart(_ autoStart: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart
        if autoStart { prepareAudioSession() }
    }

    /// The script changed (the next one in a queue, or an edit).
    func update(text: String) {
        layout = PiPTextLayout(text: text, width: frameSize.width)
        renderFrame()
    }

    func start() {
        prepareAudioSession()
        controller?.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    /// The reading screen closed.
    func tearDown() {
        if isActive { controller?.stopPictureInPicture() }
        timer?.invalidate()
        timer = nil
        possibleObservation = nil
        controller = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Picture in Picture needs an audio session that can play. Voice Scroll's session, which
    /// also records, already can; otherwise one that mixes, so other apps' sound keeps playing.
    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)
    }

    // MARK: Rendering

    private func startRendering() {
        timer?.invalidate()
        // A frame now, so the window has something to show the moment it opens.
        renderFrame()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Keeps firing while scrolling views are tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Full rate while the window shows, an occasional frame otherwise to stay ready.
    private var idleTicks = 0
    private func tick() {
        if isActive {
            renderFrame()
        } else {
            idleTicks += 1
            if idleTicks >= 15 { idleTicks = 0; renderFrame() }
        }
    }

    /// How far through the script the reader is, smoothly between words in lyrics style.
    private var readingFraction: Double {
        guard let viewModel else { return 0 }
        if viewModel.isWordMode, let count = viewModel.scriptWords?.count, count > 0 {
            return min(1, max(0, viewModel.wordPosition / Double(count)))
        }
        return viewModel.progress
    }

    private func renderFrame() {
        guard let layout, let buffer = makePixelBuffer() else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(frameSize.width), height: Int(frameSize.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        layout.draw(in: context, size: frameSize, fraction: readingFraction)
        enqueue(buffer)
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(frameSize.width),
                kCVPixelBufferHeightKey as String: Int(frameSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}

// MARK: - Playback controls

extension TeleprompterPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated {
            guard let viewModel else { return }
            if playing { viewModel.play() } else { viewModel.pause() }
        }
    }

    /// Live, like a broadcast: no timeline to scrub.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { !(viewModel?.isPlaying ?? false) }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    /// The skip buttons move a phrase back or forward.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping @Sendable () -> Void) {
        MainActor.assumeIsolated {
            if skipInterval.seconds < 0 { viewModel?.tapReverse() } else { viewModel?.tapAdvance() }
            renderFrame()
        }
        completionHandler()
    }
}

extension TeleprompterPiP: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isActive = false }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        completionHandler(true)
    }
}

// MARK: - Text layout

/// The script laid out once in lines; each frame draws only the lines in view.
private struct PiPTextLayout {
    private struct Line {
        let line: CTLine
        let top: CGFloat
        let ascent: CGFloat
        let height: CGFloat
    }

    private let lines: [Line]
    private let totalHeight: CGFloat
    private let margin: CGFloat = 44

    init(text: String, width: CGFloat) {
        let content = text.isEmpty ? String(localized: "Script is empty") : text
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 54, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 54, nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 10
        paragraph.paragraphSpacing = 24
        let attributed = NSAttributedString(string: content, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            .paragraphStyle: paragraph,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let available = width - margin * 2
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: available, height: .greatestFiniteMagnitude), nil)
        let height = ceil(suggested.height) + 2
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: available, height: height), transform: nil), nil)
        let ctLines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var built: [Line] = []
        for (index, line) in ctLines.enumerated() {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            // Core Text measures from the bottom; this keeps tops, measured from the top.
            built.append(Line(line: line, top: height - origins[index].y - ascent,
                              ascent: ascent, height: ascent + descent))
        }
        lines = built
        totalHeight = height
    }

    func draw(in context: CGContext, size: CGSize, fraction: Double) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        // The line being read rests a third of the way down; read lines dim above it.
        let readingY = size.height * 0.32
        let offset = CGFloat(fraction) * max(0, totalHeight - 60)
        for line in lines {
            let y = readingY + line.top - offset
            guard y + line.height > -10, y < size.height + 10 else { continue }
            let isRead = line.top + line.height < offset
            context.setFillColor(CGColor(gray: 1, alpha: isRead ? 0.35 : 1))
            context.textPosition = CGPoint(x: margin, y: size.height - y - line.ascent)
            CTLineDraw(line.line, context)
        }

        // Soft edges at the top and bottom.
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space,
                                     colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
                                     locations: [0, 1]) {
            let fade: CGFloat = 54
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height),
                                       end: CGPoint(x: 0, y: size.height - fade), options: [])
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: fade), options: [])
        }
    }
}

/// Hosts the layer Picture in Picture shows; it has to be in the reading screen's window.
struct PiPSourceView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        layer.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        layer.frame = view.bounds
    }
}
#endif
