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

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4)
        let br = min(bottomRadius, max(0, rect.width / 2 - tr), max(0, rect.height - tr))
        var path = Path()

        // Top-left inverted corner — log-like cubic: stays along the bezel, then eases down.
        // Tangents: horizontal at the tip, vertical where it meets the side.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(
            to: CGPoint(x: tr, y: tr),
            control1: CGPoint(x: tr * 0.72, y: 0),
            control2: CGPoint(x: tr, y: tr * 0.28)
        )

        // Left edge → bottom-left
        path.addLine(to: CGPoint(x: tr, y: rect.height - br))
        path.addCurve(
            to: CGPoint(x: tr + br, y: rect.height),
            control1: CGPoint(x: tr, y: rect.height - br * 0.45),
            control2: CGPoint(x: tr + br * 0.45, y: rect.height)
        )

        // Bottom edge → bottom-right
        path.addLine(to: CGPoint(x: rect.width - tr - br, y: rect.height))
        path.addCurve(
            to: CGPoint(x: rect.width - tr, y: rect.height - br),
            control1: CGPoint(x: rect.width - tr - br * 0.45, y: rect.height),
            control2: CGPoint(x: rect.width - tr, y: rect.height - br * 0.45)
        )

        // Right edge → top-right inverted corner (mirror of top-left)
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
    @State private var scrollOffset: CGFloat = 0
    @State private var contentSize: CGFloat = 0
    @State private var viewportSize: CGFloat = 260

    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private var menuBarH: CGFloat { NSStatusBar.system.thickness }
    private var textBandH: CGFloat { manager.notchTextBandHeight() }
    private var isVertical: Bool { manager.notchScrollVertical }

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

            GeometryReader { geo in
                ZStack(alignment: isVertical ? .top : .leading) {
                    Color.black
                    scrollingText(in: geo)
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
        }
        .frame(height: menuBarH + textBandH)
        .clipShape(
            NotchShape(
                topRadius: FloatingTeleprompterManager.notchTopRadius,
                bottomRadius: FloatingTeleprompterManager.notchBottomRadius
            )
        )
        .compositingGroup()
        .scaleEffect(
            x: manager.notchPresented ? 1 : 0.52,
            y: manager.notchPresented ? 1 : 0.12,
            anchor: .top
        )
        .opacity(manager.notchPresented ? 1 : 0)
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
                .font(.system(size: manager.notchFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, FloatingTeleprompterManager.notchTopRadius + 6)
                .frame(width: geo.size.width, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(contentSizeReader(viewport: geo.size.height))
                .offset(y: scrollOffset)
        } else {
            Text(text)
                .font(.system(size: manager.notchFontSize, weight: .semibold))
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
        guard viewModel.isPlaying else { return }
        let pixelsPerFrame = AppConstants.basePixelsPerSecond * viewModel.scrollSpeed / 60.0
        scrollOffset -= pixelsPerFrame
        if contentSize > 0 && scrollOffset < -(contentSize + 20) {
            scrollOffset = viewportSize
            viewModel.notchProgress = 0
            viewModel.pause()
            viewModel.isFinished = true
        } else if contentSize > 0 {
            let totalSpan = viewportSize + contentSize
            if totalSpan > 0 {
                viewModel.notchProgress = Double(max(0, min(1, (viewportSize - scrollOffset) / totalSpan)))
            }
        }
    }
}
#endif
