//
//  TeleprompterPiPManager.swift
//  yprompt
//

#if os(iOS)
import AVKit
import AVFoundation
import Combine
import UIKit
import SwiftUI

@MainActor
final class TeleprompterPiPManager: NSObject, ObservableObject {
    static let shared = TeleprompterPiPManager()

    @Published var isPiPActive = false
    @Published var isPiPAvailable = false

    private var pipController: AVPictureInPictureController?
    private var sampleBufferLayer: AVSampleBufferDisplayLayer?
    private var displayLink: CADisplayLink?
    private var audioEngine: AVAudioEngine?

    private var viewModel: TeleprompterViewModel?
    private var script: Script?

    // Accessed from nonisolated delegate methods — only written on main thread
    nonisolated(unsafe) private var _isPaused: Bool = true
    nonisolated(unsafe) private var _renderSize: CGSize = CGSize(width: 480, height: 270)

    private var availabilityObservation: NSKeyValueObservation?

    private override init() { super.init() }

    // MARK: - Public API

    func configure(script: Script, viewModel: TeleprompterViewModel) {
        self.script = script
        self.viewModel = viewModel
        if pipController == nil {
            setupAudioSession()
            setupPiP()
        }
    }

    func togglePiP() {
        if isPiPActive {
            pipController?.stopPictureInPicture()
        } else {
            pipController?.startPictureInPicture()
        }
    }

    // MARK: - Audio Session (keeps PiP alive in background)

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
        startSilentAudio()
    }

    private func startSilentAudio() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410) else { return }
        buffer.frameLength = 4410
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        audioEngine = engine
    }

    // MARK: - PiP Setup

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        sampleBufferLayer = layer

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        pipController = controller

        availabilityObservation = controller.observe(
            \.isPictureInPicturePossible, options: [.initial, .new]
        ) { [weak self] ctrl, _ in
            Task { @MainActor [weak self] in
                self?.isPiPAvailable = ctrl.isPictureInPicturePossible
            }
        }

        startDisplayLink()
    }

    // MARK: - Render Loop

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard let vm = viewModel, let sc = script else { return }
        _isPaused = !vm.isPlaying

        let content = sc.content.isEmpty ? "[ Empty script ]" : sc.content
        let customization = sc.customization
        let offset = vm.contentOffset
        let size = _renderSize

        guard let pixelBuffer = makePixelBuffer(size: size) else { return }
        render(content: content, customization: customization, offset: offset, into: pixelBuffer, size: size)
        if let sb = makeSampleBuffer(from: pixelBuffer) {
            sampleBufferLayer?.enqueue(sb)
        }
    }

    // MARK: - CoreGraphics Rendering

    private func render(
        content: String,
        customization: TextCustomization,
        offset: CGFloat,
        into pixelBuffer: CVPixelBuffer,
        size: CGSize
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(
                data: base,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }

        // Flip Y: CGContext origin is bottom-left
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        // Background
        ctx.setFillColor(UIColor(Color(hex: customization.backgroundColorHex)).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // Text attributes
        let scale = size.height / 400.0
        let fontSize = (customization.fontSize * scale).clamped(to: 10...72)
        let font = UIFont(name: customization.fontName, size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize)

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = customization.textAlignmentIndex.nsTextAlignment
        paraStyle.lineHeightMultiple = customization.lineHeight

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(Color(hex: customization.textColorHex)),
            .paragraphStyle: paraStyle
        ]

        let padding = 16.0 * scale
        let drawRect = CGRect(
            x: padding,
            y: padding - offset * scale,
            width: size.width - padding * 2,
            height: size.height * 20
        )

        UIGraphicsPushContext(ctx)
        content.draw(in: drawRect, withAttributes: attrs)
        UIGraphicsPopContext()
    }

    private func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        ) == kCVReturnSuccess else { return nil }
        return pb
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var desc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &desc
        )
        guard let desc else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sb
        )
        return sb
    }

    deinit {
        displayLink?.invalidate()
        audioEngine?.stop()
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension TeleprompterPiPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.isPiPActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.isPiPActive = false }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension TeleprompterPiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        Task { @MainActor in
            if playing { self.viewModel?.play() } else { self.viewModel?.pause() }
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        _isPaused
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        _renderSize = CGSize(
            width: CGFloat(newRenderSize.width),
            height: CGFloat(newRenderSize.height)
        )
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Int {
    var nsTextAlignment: NSTextAlignment {
        switch self {
        case 1: return .center
        case 2: return .right
        default: return .left
        }
    }
}
#endif
