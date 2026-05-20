//
//  FloatingTeleprompterView.swift
//  yprompt
//

#if os(macOS)
import SwiftUI

struct FloatingTeleprompterView: View {
    @ObservedObject private var manager: FloatingTeleprompterManager
    @ObservedObject private var viewModel: TeleprompterViewModel
    @State private var isHovering = false

    init() {
        let mgr = FloatingTeleprompterManager.shared
        _manager = ObservedObject(wrappedValue: mgr)
        _viewModel = ObservedObject(wrappedValue: mgr.viewModel)
    }

    private var customization: TextCustomization {
        manager.currentScript?.customization ?? TextCustomization()
    }

    var body: some View {
        ZStack {
            // Layer 1: glass blur (ultraThinMaterial blurs content behind the panel)
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .opacity(manager.blurAmount)

            // Layer 2: solid black overlay — opacity controlled separately
            RoundedRectangle(cornerRadius: 18)
                .fill(.black.opacity(manager.backgroundOpacity))

            // Layer 3: scrolling text
            GeometryReader { geo in
                scrollableText
                    .frame(width: geo.size.width)
                    .clipped()
                    .onAppear { viewModel.screenHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in viewModel.screenHeight = h }
            }

            // Layer 4: top/bottom fade — matches the solid background opacity
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(manager.backgroundOpacity), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 22)
                .allowsHitTesting(false)
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(manager.backgroundOpacity)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 22)
                .allowsHitTesting(false)
            }

            // Layer 5: hover controls
            if isHovering {
                controlsBar
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .onChange(of: manager.currentScript?.id) { viewModel.resetToTop() }
    }

    // MARK: - Scrolling text

    private var scrollableText: some View {
        let content = manager.currentScript?.content ?? ""
        let text = content.isEmpty ? "[ No script — pick one from the menu bar ]" : content
        return Text(text)
            .font(.custom(customization.fontName, size: 19))
            .foregroundStyle(.white)
            .multilineTextAlignment(customization.textAlignmentIndex.textAlignment)
            .lineSpacing(4)
            .padding(.horizontal, 52)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: customization.textAlignmentIndex.frameAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { viewModel.contentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in viewModel.contentHeight = h }
                }
            )
            .offset(y: -viewModel.contentOffset)
    }

    // MARK: - Hover controls (two rows)

    private var controlsBar: some View {
        VStack(spacing: 6) {
            // Row 1 — playback
            HStack(spacing: 12) {
                Button { viewModel.resetToTop() } label: {
                    Image(systemName: "backward.end.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("Reset to top")

                Button { viewModel.togglePlayPause() } label: {
                    Image(
                        systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                    )
                    .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(viewModel.isPlaying ? "Pause" : "Play")

                Slider(
                    value: $viewModel.scrollSpeed,
                    in: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                    step: 0.1
                )
                .frame(width: 80)
                .controlSize(.mini)

                Text(String(format: "%.1fx", viewModel.scrollSpeed))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 28)

                Spacer()

                Button { FloatingTeleprompterManager.shared.hide() } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .help("Close")
            }

            // Row 2 — appearance
            HStack(spacing: 8) {
                // Solid background opacity
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .help("Background opacity")

                Slider(value: $manager.backgroundOpacity, in: 0.15...1.0, step: 0.05)
                    .controlSize(.mini)

                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1, height: 10)

                // Glass blur
                Image(systemName: "camera.filters")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .help("Background blur")

                Slider(value: $manager.blurAmount, in: 0.0...1.0, step: 0.05)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
#endif
