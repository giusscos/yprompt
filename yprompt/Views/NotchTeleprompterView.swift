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
    @State private var xOffset: CGFloat = 260
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 260

    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private var menuBarH: CGFloat { NSStatusBar.system.thickness }

    private var text: String {
        let content = manager.currentScript?.content ?? ""
        return content.isEmpty
            ? "[ No script selected ]"
            : content.replacingOccurrences(of: "\n", with: "   ·   ")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top black block covers the notch area in the menu bar
            Color.black
                .frame(height: menuBarH)

            // Bottom pill: text scrolls here, just below the notch
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.black
                    Text(text)
                        .font(.system(size: manager.notchFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .background(
                            GeometryReader { tg in
                                Color.clear
                                    .onAppear {
                                        textWidth = tg.size.width
                                        containerWidth = geo.size.width
                                        xOffset = geo.size.width
                                    }
                                    .onChange(of: tg.size.width) { _, w in textWidth = w }
                            }
                        )
                        .offset(x: xOffset)
                }
                .clipped()
                .onChange(of: geo.size.width) { _, w in containerWidth = w }
            }
        }
        .clipShape(
            NotchShape(
                topRadius: FloatingTeleprompterManager.notchTopRadius,
                bottomRadius: FloatingTeleprompterManager.notchBottomRadius
            )
        )
        .scaleEffect(
            x: manager.notchPresented ? 1 : 0.52,
            y: manager.notchPresented ? 1 : 0.12,
            anchor: .top
        )
        .opacity(manager.notchPresented ? 1 : 0)
        .onReceive(ticker) { _ in
            guard viewModel.isPlaying else { return }
            let pixelsPerFrame = AppConstants.basePixelsPerSecond * viewModel.scrollSpeed / 60.0
            xOffset -= pixelsPerFrame
            if textWidth > 0 && xOffset < -(textWidth + 20) {
                xOffset = containerWidth
                viewModel.notchProgress = 0
                viewModel.pause()
                viewModel.isFinished = true
            } else if textWidth > 0 {
                let totalSpan = containerWidth + textWidth
                if totalSpan > 0 {
                    viewModel.notchProgress = Double(max(0, min(1, (containerWidth - xOffset) / totalSpan)))
                }
            }
        }
        .onReceive(viewModel.notchSeekRequest) { fraction in
            guard textWidth > 0 else { return }
            let totalSpan = containerWidth + textWidth
            xOffset = containerWidth - CGFloat(fraction) * totalSpan
            viewModel.notchProgress = fraction
        }
        .onReceive(manager.notchScrollDelta) { delta in
            xOffset += delta
        }
        .onChange(of: text) { _, _ in
            xOffset = containerWidth
            viewModel.notchProgress = 0
        }
        .onReceive(viewModel.resetPublisher) {
            xOffset = containerWidth
            viewModel.notchProgress = 0
        }
        .onTapGesture {
            viewModel.togglePlayPause()
        }
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
#endif
