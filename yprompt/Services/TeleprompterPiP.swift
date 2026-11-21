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
import os

/// Why Picture in Picture or its audio failed, in debug builds.
nonisolated private func pipLog(_ message: String) {
    #if DEBUG
    print("[PiP]", message)
    #endif
}

/// The script in a Picture in Picture window, over any other app: read while recording in
/// the Camera app, Instagram or TikTok, or during a FaceTime or Zoom call.
///
/// Picture in Picture shows video, so the script is drawn into video frames, about 30 a
/// second, following the reading screen's scroll position. The window's play and skip
/// buttons control the scrolling.
@MainActor
final class TeleprompterPiP: NSObject, ObservableObject {
    @Published private(set) var isActive = false

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    let displayLayer = AVSampleBufferDisplayLayer()

    private var controller: AVPictureInPictureController?
    private weak var viewModel: TeleprompterViewModel?
    private var layout: PiPTextLayout?
    private var style: PiPStyle?
    private var timer: Timer?
    private var pool: CVPixelBufferPool?
    /// Read by Picture in Picture from its own threads.
    private let pausedState = OSAllocatedUnfairLock(initialState: true)
    /// iOS only lets an app that is playing media open Picture in Picture.
    private let silence = SilentAudio()
    private var autoStart = false

    /// Landscape, so a line of the script fits across; the window can be resized.
    private let frameSize = CGSize(width: 960, height: 540)

    // MARK: Setup

    /// Ties the window to the reading screen's script and scrolling.
    /// `autoStart`: swiping home while reading floats the script, like a video does.
    func configure(viewModel: TeleprompterViewModel, style: PiPStyle, autoStart: Bool) {
        self.viewModel = viewModel
        update(style: style)
        displayLayer.videoGravity = .resizeAspect
        if displayLayer.controlTimebase == nil {
            // A running clock, so the frames count as live video playing.
            var timebase: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
            if let timebase {
                CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
                CMTimebaseSetRate(timebase, rate: 1)
                displayLayer.controlTimebase = timebase
            }
        }
        // Before the controller exists: it only offers Picture in Picture to apps that can play.
        prepareAudioSession()
        if controller == nil, Self.isSupported {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                    playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            self.controller = controller
        }
        setAutoStart(autoStart)
        startRendering()
    }

    /// Pro only, like the button; follows a purchase made while reading.
    func setAutoStart(_ autoStart: Bool) {
        self.autoStart = autoStart
        controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart
        // Floating on the way out of the app needs media already playing.
        if autoStart { silence.start() } else if !isActive { silence.stop() }
    }

    /// The script changed (the next one in a queue, or an edit).
    func update(style: PiPStyle) {
        guard style != self.style else { return }
        self.style = style
        layout = PiPTextLayout(style: style, width: frameSize.width)
        renderFrame()
    }

    func start() {
        prepareAudioSession()
        silence.start()
        renderFrame()
        guard let controller else { return }
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            // Picture in Picture can be unavailable for a moment while the screen lays out.
            Task {
                for _ in 0..<10 where !controller.isPictureInPicturePossible {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                controller.startPictureInPicture()
            }
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    /// The reading screen closed.
    func tearDown() {
        if isActive { controller?.stopPictureInPicture() }
        timer?.invalidate()
        timer = nil
        silence.stop()
        controller = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Picture in Picture needs an audio session that can play. Voice Scroll's session, which
    /// also records, already can; otherwise one that mixes, so other apps' sound keeps playing.
    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            pipLog("audio session: \(error.localizedDescription)")
        }
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

    /// Always at full rate: with frames arriving slowly, iOS treats the video as stalled and
    /// stops offering Picture in Picture.
    private func tick() {
        let paused = !(viewModel?.isPlaying ?? false)
        pausedState.withLock { $0 = paused }
        renderFrame()
    }

    /// Where the reader is: a word in lyrics style, a fraction of the script otherwise.
    private var position: PiPTextLayout.Position {
        guard let viewModel else { return .fraction(0) }
        if viewModel.isWordMode, layout?.isWordLayout == true {
            return .word(viewModel.wordPosition)
        }
        return .fraction(viewModel.progress)
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

        layout.draw(in: context, size: frameSize, position: position)
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
        if renderer.status == .failed {
            pipLog("renderer failed: \(String(describing: renderer.error))")
            renderer.flush()
        }
        renderer.enqueue(sample)
    }
}

// MARK: - Playback controls

extension TeleprompterPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        pausedState.withLock { $0 = !playing }
        Task { @MainActor in
            guard let viewModel else { return }
            if playing { viewModel.play() } else { viewModel.pause() }
        }
    }

    /// Live, like a broadcast: no timeline to scrub.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        pausedState.withLock { $0 }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    /// The skip buttons move a phrase back or forward.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping @Sendable () -> Void) {
        Task { @MainActor in
            if skipInterval.seconds < 0 { viewModel?.tapReverse() } else { viewModel?.tapAdvance() }
            renderFrame()
            completionHandler()
        }
    }
}

extension TeleprompterPiP: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in isActive = true }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        pipLog("failed to start: \(error.localizedDescription)")
        Task { @MainActor in isActive = false }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            isActive = false
            if !autoStart { silence.stop() }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        completionHandler(true)
    }
}

// MARK: - Silent audio

/// A loop of silence. Mixes with other apps' sound, so music or a call carries on as before.
@MainActor
private final class SilentAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    func start() {
        guard engine?.isRunning != true else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            pipLog("no audio format")
            return
        }
        buffer.frameLength = buffer.frameCapacity // Zeros: silence.
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            pipLog("silent audio: \(error.localizedDescription)")
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}

// MARK: - Text layout

/// What the Picture in Picture window shows, taken from the reading screen.
struct PiPStyle: Equatable {
    var text: String
    /// Set in lyrics style: read words light up, a line at a time.
    var words: ScriptWords?
    var textColorHex: String
    var backgroundColorHex: String
    var font: ReadingFont
}

/// The script laid out once in lines; each frame draws only the lines in view.
private final class PiPTextLayout {
    enum Position {
        case fraction(Double)
        case word(Double)
    }

    private struct Line {
        let line: CTLine
        let range: CFRange
        let top: CGFloat
        let ascent: CGFloat
        let height: CGFloat
    }

    private let lines: [Line]
    private let totalHeight: CGFloat
    private let margin: CGFloat = 44
    private let textColor: CGColor
    private let backgroundColor: CGColor
    /// Each word's place in the laid-out text, in lyrics style.
    private let wordRanges: [NSRange]
    /// Eased toward the current line, so lyrics style glides from line to line.
    private var shownOffset: CGFloat?

    var isWordLayout: Bool { !wordRanges.isEmpty }

    // The reading screen's own opacities in lyrics style.
    private let upcomingOpacity: CGFloat = 0.42
    private let pastOpacity: CGFloat = 0.22

    init(style: PiPStyle, width: CGFloat) {
        textColor = UIColor(Color(hex: style.textColorHex)).cgColor
        backgroundColor = UIColor(Color(hex: style.backgroundColorHex)).cgColor

        var content = ""
        var ranges: [NSRange] = []
        if let words = style.words, !words.isEmpty {
            for word in words.words {
                let start = (content as NSString).length
                content += word.text
                ranges.append(NSRange(location: start, length: (word.text as NSString).length))
                if word.breaksAfter > 0 {
                    content += String(repeating: "\n", count: word.breaksAfter)
                } else if word.spaceAfter {
                    content += " "
                }
            }
        } else {
            content = style.text
        }
        if content.isEmpty { content = String(localized: "Script is empty") }
        wordRanges = ranges

        let font = style.font.resolved(for: content).platformFont(size: 50, weight: .semibold) as CTFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 10
        paragraph.paragraphSpacing = 18
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
            built.append(Line(line: line, range: CTLineGetStringRange(line),
                              top: height - origins[index].y - ascent,
                              ascent: ascent, height: ascent + descent))
        }
        lines = built
        totalHeight = height
    }

    func draw(in context: CGContext, size: CGSize, position: Position) {
        context.setFillColor(backgroundColor)
        context.fill(CGRect(origin: .zero, size: size))

        switch position {
        case .fraction(let fraction):
            // The line being read rests a third of the way down.
            let offset = CGFloat(fraction) * max(0, totalHeight - 60)
            for line in lines {
                draw(line, in: context, size: size, y: size.height * 0.32 + line.top - offset, opacity: 1)
            }
        case .word(let wordPosition):
            drawLyrics(in: context, size: size, wordPosition: wordPosition)
        }

        // Soft edges at the top and bottom, into the background.
        let clear = backgroundColor.copy(alpha: 0) ?? backgroundColor
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: [backgroundColor, clear] as CFArray, locations: [0, 1]) {
            let fade: CGFloat = 54
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height),
                                       end: CGPoint(x: 0, y: size.height - fade), options: [])
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: fade), options: [])
        }
    }

    /// Like the reading screen: the current line near the top, its read words lit up and the
    /// word being read filling in; lines read dim, lines to come half bright.
    private func drawLyrics(in context: CGContext, size: CGSize, wordPosition: Double) {
        guard !wordRanges.isEmpty else { return }
        let index = min(wordRanges.count - 1, max(0, Int(wordPosition)))
        let fill = CGFloat(min(1, max(0, wordPosition - Double(index))))
        let word = wordRanges[index]
        let currentLine = lines.firstIndex { line in
            word.location >= line.range.location && word.location < line.range.location + line.range.length
        } ?? 0

        let target = lines.isEmpty ? 0 : lines[currentLine].top
        let offset = shownOffset.map { $0 + (target - $0) * 0.18 } ?? target
        shownOffset = abs(offset - target) < 0.5 ? target : offset
        let anchor = size.height * 0.24

        for (lineIndex, line) in lines.enumerated() {
            let y = anchor + line.top - offset
            if lineIndex < currentLine {
                draw(line, in: context, size: size, y: y, opacity: pastOpacity)
            } else if lineIndex > currentLine {
                draw(line, in: context, size: size, y: y, opacity: upcomingOpacity)
            } else {
                draw(line, in: context, size: size, y: y, opacity: upcomingOpacity)
                let start = CTLineGetOffsetForStringIndex(line.line, word.location, nil)
                let end = CTLineGetOffsetForStringIndex(line.line, word.location + word.length, nil)
                let litWidth = start + (end - start) * fill
                guard litWidth > 0 else { continue }
                context.saveGState()
                context.clip(to: CGRect(x: margin, y: 0, width: litWidth, height: size.height))
                draw(line, in: context, size: size, y: y, opacity: 1)
                context.restoreGState()
            }
        }
    }

    private func draw(_ line: Line, in context: CGContext, size: CGSize, y: CGFloat, opacity: CGFloat) {
        guard y + line.height > -10, y < size.height + 10 else { return }
        context.setFillColor(textColor.copy(alpha: textColor.alpha * opacity) ?? textColor)
        context.textPosition = CGPoint(x: margin, y: size.height - y - line.ascent)
        CTLineDraw(line.line, context)
    }
}

/// Hosts the layer Picture in Picture shows; it has to be in the reading screen's window.
struct PiPSourceView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> PiPLayerHost {
        PiPLayerHost(displayLayer: layer)
    }

    func updateUIView(_ view: PiPLayerHost, context: Context) {}
}

/// Sizes the layer only when its own size changes, without animation: each change makes
/// Picture in Picture briefly unavailable.
final class PiPLayerHost: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard displayLayer.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}
#endif
