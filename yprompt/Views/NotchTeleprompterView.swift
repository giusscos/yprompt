//
//  NotchTeleprompterView.swift
//  yprompt
//

#if os(macOS)
import SwiftUI
import Combine

struct NotchTeleprompterView: View {
    @ObservedObject private var manager: FloatingTeleprompterManager
    @ObservedObject private var viewModel: TeleprompterViewModel
    @State private var xOffset: CGFloat = 260
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 260

    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private var menuBarH: CGFloat { NSStatusBar.system.thickness }

    init() {
        let mgr = FloatingTeleprompterManager.shared
        _manager = ObservedObject(wrappedValue: mgr)
        _viewModel = ObservedObject(wrappedValue: mgr.viewModel)
    }

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
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 0
                )
            )
        }
        .onReceive(ticker) { _ in
            guard viewModel.isPlaying else { return }
            let pixelsPerFrame = AppConstants.basePixelsPerSecond * viewModel.scrollSpeed / 60.0
            xOffset -= pixelsPerFrame
            if textWidth > 0 && xOffset < -(textWidth + 20) {
                xOffset = containerWidth
            }
        }
        .onReceive(manager.notchScrollDelta) { delta in
            xOffset += delta
        }
        .onChange(of: text) { _, _ in
            xOffset = containerWidth
        }
        .onReceive(viewModel.resetPublisher) {
            xOffset = containerWidth
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
