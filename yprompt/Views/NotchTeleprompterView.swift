//
//  NotchTeleprompterView.swift
//  yprompt
//

#if os(macOS)
import SwiftUI
import Combine

/// MacBook-style notch silhouette: concave top corners that flare into the bezel
/// with a log-like ease (hug the top, then fall into the side), plus rounded bottoms.
struct NotchShape: Shape {
    var topRadius: CGFloat = 12
    var bottomRadius: CGFloat = 14

    /// The bottom corners grow and shrink with the camera.
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4)
        let br = min(bottomRadius, max(0, rect.width / 2 - tr), max(0, rect.height / 2))
        var path = Path()

        // Top-left inverted corner — log-like cubic: stays along the bezel, then eases down.
        // Tangents: horizontal at the tip, vertical where it meets the side.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(
            to: CGPoint(x: tr, y: tr),
            control1: CGPoint(x: tr * 0.72, y: 0),
            control2: CGPoint(x: tr, y: tr * 0.28)
        )

        // The body: straight sides and continuous ("squircle") bottom corners, as Apple's own
        // rounded shapes are drawn.
        path.addLine(to: CGPoint(x: tr, y: 0))
        path.closeSubpath()
        let body = CGRect(x: tr, y: 0, width: max(0, rect.width - 2 * tr), height: rect.height)
        path.addPath(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: br,
                                            bottomTrailingRadius: br, topTrailingRadius: 0,
                                            style: .continuous).path(in: body))

        // Top-right inverted corner (mirror of top-left)
        path.move(to: CGPoint(x: rect.width - tr, y: 0))
        path.addLine(to: CGPoint(x: rect.width - tr, y: tr))
        path.addCurve(
            to: CGPoint(x: rect.width, y: 0),
            control1: CGPoint(x: rect.width - tr, y: tr * 0.28),
            control2: CGPoint(x: rect.width - tr * 0.72, y: 0)
        )

        path.closeSubpath()
        return path
    }
}

struct NotchTeleprompterView: View {
    private let manager = FloatingTeleprompterManager.shared
    private var viewModel: TeleprompterViewModel { manager.viewModel }
    @AppStorage(ReadingFont.key) private var readingFont: ReadingFont = .system
    @AppStorage(LetterSpacing.key) private var letterSpacing: LetterSpacing = .normal
    @AppStorage(AppConstants.lyricsStyleKey) private var lyricsStyleEnabled = true
    /// Vertical scrolling: 0 left (the default, easiest to read), 1 centered.
    @AppStorage(AppConstants.notchAlignmentKey) private var verticalAlignment = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var contentSize: CGFloat = 0
    @State private var viewportSize: CGFloat = 260

    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private var menuBarH: CGFloat { FloatingTeleprompterManager.notchStripHeight }
    private var textBandH: CGFloat { manager.notchTextBandHeight() }
    private var isVertical: Bool { manager.notchScrollVertical }
    private var showsCamera: Bool { manager.notchShowsCamera }

    /// The same rule as the floating window: lyrics style is Pro, Voice needs it to show the
    /// word being read, and the sample script lets everyone try it.
    private var usesWordStyle: Bool {
        guard let words = viewModel.scriptWords, !words.isEmpty, !words.isRightToLeft else { return false }
        if viewModel.voiceScrollEnabled { return true }
        return lyricsStyleEnabled && (manager.isPremium || manager.currentScript?.id == AppConstants.welcomeScriptID)
    }

    private var horizontalInset: CGFloat { FloatingTeleprompterManager.notchTopRadius + 8 }

    /// Vertical: lines fade out as they reach the bottom of the band. Horizontal: words fade
    /// in at the right edge and out at the left one.
    @ViewBuilder
    private var textFade: some View {
        if isVertical {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(26, textBandH * 0.3))
            }
        } else {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: horizontalInset + 22)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: horizontalInset + 22)
            }
        }
    }

    private var text: String {
        let content = manager.currentScript?.content ?? ""
        if content.isEmpty { return "[ No script selected ]" }
        if isVertical { return content }
        return content.replacingOccurrences(of: "\n", with: "   ·   ")
    }

    var body: some View {
        // Fixed-height silhouette pinned to the top; panel includes bounce slack below
        // so spring overshoot can draw full bottom radii without a hard window clip.
        VStack(spacing: 0) {
            Color.black
                .frame(height: menuBarH)
                .overlay(alignment: .leading) {
                    // Beside the camera, where the reader is looking.
                    if manager.capture.isRecording, let start = manager.capture.recordingStartDate {
                        RecordingBadge(start: start, compact: true)
                            .padding(.leading, FloatingTeleprompterManager.notchTopRadius + 12)
                    }
                }

            GeometryReader { geo in
                ZStack(alignment: isVertical ? .top : .leading) {
                    Color.black
                    Group {
                    if viewModel.isWordMode, let words = viewModel.scriptWords {
                        WordTeleprompterView(
                            viewModel: viewModel,
                            words: words,
                            fontSize: manager.notchFontSize,
                            lineHeightMultiple: 1.15,
                            textColor: .white,
                            alignment: isVertical ? verticalAlignment : 0,
                            horizontalPadding: horizontalInset,
                            topInset: isVertical ? 4 : 0,
                            anchor: 0,
                            upcomingOpacity: 0.5,
                            pastOpacity: 0.3,
                            singleLine: !isVertical
                        )
                    } else {
                        scrollingText(in: geo)
                    }
                    }
                    // The text itself fades out at the band's edges, so whatever is below
                    // (the camera, or the notch's own edge) stays fully visible.
                    .mask(textFade)
                }
                .clipped()
                .onAppear { resetScroll(viewport: primaryAxis(of: geo.size)) }
                .onChange(of: geo.size.width) { _, _ in
                    viewportSize = primaryAxis(of: geo.size)
                }
                .onChange(of: geo.size.height) { _, _ in
                    viewportSize = primaryAxis(of: geo.size)
                }
            }
            .frame(height: textBandH)

            // The camera's room under the text. Only its height changes; the black and the
            // rounded outline belong to the whole notch, so the shape never looks square.
            GeometryReader { room in
                let inset = FloatingTeleprompterManager.notchCameraInset
                // Kept, attached to the camera, for as long as the camera runs, even with no room:
                // it's ready the moment the notch opens, and on the way out it shrinks and fades
                // with the notch rather than leaving at full size and being cut off.
                if let session = manager.capture.captureSession, manager.notchMode {
                    // Under the text, so the eyes stay by the lens while checking the framing.
                    // It takes the room's animated height, so it grows and shrinks with the
                    // notch with its corners rounded all the way, instead of being cut off.
                    let radius = FloatingTeleprompterManager.notchCameraBottomRadius - inset
                    CameraPreviewLayerView(session: session, mirrored: manager.mirrorsCamera)
                        .overlay { DemoCameraPicture() }
                        .frame(height: max(0, room.size.height - inset))
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .padding(.horizontal, FloatingTeleprompterManager.notchTopRadius + inset)
                        .opacity(showsCamera ? 1 : 0)
                }
            }
            .frame(height: showsCamera ? FloatingTeleprompterManager.notchCameraHeight : 0, alignment: .top)
            .clipped()
        }
        .frame(height: menuBarH + textBandH + (showsCamera ? FloatingTeleprompterManager.notchCameraHeight : 0),
               alignment: .top)
        .background(Color.black)
        .clipShape(
            NotchShape(
                topRadius: FloatingTeleprompterManager.notchTopRadius,
                bottomRadius: showsCamera
                    ? FloatingTeleprompterManager.notchCameraBottomRadius
                    : (isVertical ? FloatingTeleprompterManager.notchBottomRadius
                                  : FloatingTeleprompterManager.notchTickerBottomRadius)
            )
        )
        .compositingGroup()
        .scaleEffect(
            x: manager.notchPresented ? 1 : 0.52,
            y: manager.notchPresented ? 1 : 0.12,
            anchor: .top
        )
        .opacity(manager.notchPresented ? 1 : 0)
        // Text size and the camera grow and shrink the notch smoothly, text and black together.
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: manager.notchFontSize)
        .animation(.spring(response: 0.5, dampingFraction: 0.84), value: showsCamera)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(ticker) { _ in tickScroll() }
        .onReceive(viewModel.notchSeekRequest) { fraction in
            guard contentSize > 0 else { return }
            let totalSpan = viewportSize + contentSize
            scrollOffset = viewportSize - CGFloat(fraction) * totalSpan
            viewModel.notchProgress = fraction
        }
        .onReceive(manager.notchScrollDelta) { delta in
            scrollOffset += delta
        }
        .onChange(of: usesWordStyle, initial: true) { _, usesWords in viewModel.setWordMode(usesWords) }
        .onChange(of: text) { _, _ in resetScroll(viewport: viewportSize) }
        .onChange(of: isVertical) { _, _ in resetScroll(viewport: viewportSize) }
        .onReceive(viewModel.resetPublisher) {
            resetScroll(viewport: viewportSize)
        }
        .onTapGesture {
            viewModel.togglePlayPause()
        }
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    @ViewBuilder
    private func scrollingText(in geo: GeometryProxy) -> some View {
        if isVertical {
            Text(text)
                .font(readingFont.resolved(for: text).font(size: manager.notchFontSize, weight: .semibold))
                .tracking(letterSpacing.tracking(for: manager.notchFontSize, in: text))
                .foregroundStyle(.white)
                .multilineTextAlignment(verticalAlignment == 1 ? .center : .leading)
                .lineSpacing(3)
                .padding(.horizontal, horizontalInset)
                .frame(width: geo.size.width, alignment: verticalAlignment == 1 ? .top : .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(contentSizeReader(viewport: geo.size.height))
                .offset(y: scrollOffset)
        } else {
            Text(text)
                .font(readingFont.resolved(for: text).font(size: manager.notchFontSize, weight: .semibold))
                .tracking(letterSpacing.tracking(for: manager.notchFontSize, in: text))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .background(contentSizeReader(viewport: geo.size.width))
                .offset(x: scrollOffset)
        }
    }

    private func contentSizeReader(viewport: CGFloat) -> some View {
        GeometryReader { tg in
            Color.clear
                .onAppear {
                    contentSize = primaryAxis(of: tg.size)
                    viewportSize = viewport
                    scrollOffset = viewport
                }
                .onChange(of: tg.size.width) { _, w in
                    if !isVertical { contentSize = w }
                }
                .onChange(of: tg.size.height) { _, h in
                    if isVertical { contentSize = h }
                }
        }
    }

    private func primaryAxis(of size: CGSize) -> CGFloat {
        isVertical ? size.height : size.width
    }

    private func resetScroll(viewport: CGFloat) {
        viewportSize = viewport
        scrollOffset = viewport
        viewModel.notchProgress = 0
    }

    private func tickScroll() {
        // Lyrics style runs on the view model's word clock instead.
        guard viewModel.isPlaying, !viewModel.isWordMode else { return }
        if viewModel.voiceScrollEnabled {
            if let heard = viewModel.voiceTrackedFraction, contentSize > 0 {
                // Ease towards the words heard so far.
                let target = viewportSize - CGFloat(heard) * (viewportSize + contentSize)
                scrollOffset += min(0, target - scrollOffset) * 0.12
                viewModel.notchProgress = heard
                if heard >= 1 && scrollOffset <= target + 1 { finish() }
                return
            }
            guard viewModel.voiceScrollService.isSpeaking else { return }
        }
        let pixelsPerFrame = viewModel.pixelsPerSecond(contentLength: contentSize, speed: viewModel.scrollSpeed) / 60.0
        scrollOffset -= pixelsPerFrame
        if contentSize > 0 && scrollOffset < -(contentSize + 20) {
            finish()
        } else if contentSize > 0 {
            let totalSpan = viewportSize + contentSize
            if totalSpan > 0 {
                viewModel.notchProgress = Double(max(0, min(1, (viewportSize - scrollOffset) / totalSpan)))
            }
        }
    }

    private func finish() {
        scrollOffset = viewportSize
        viewModel.notchProgress = 0
        viewModel.pause()
        viewModel.isFinished = true
        viewModel.onFinished?()
    }
}
#endif
