//
//  FloatingTeleprompterView.swift
//  yprompt
//

#if os(macOS)
import SwiftUI

struct FloatingTeleprompterView: View {
    private let manager = FloatingTeleprompterManager.shared
    private var viewModel: TeleprompterViewModel { manager.viewModel }
    @Environment(\.fontResolutionContext) private var fontContext
    @AppStorage(AppConstants.lyricsStyleKey) private var lyricsStyleEnabled = true
    @AppStorage(ReadingFont.key) private var readingFont: ReadingFont = .system
    @AppStorage(LetterSpacing.key) private var letterSpacing: LetterSpacing = .normal
    @State private var isHovering = false

    /// Lyrics style is Pro. Voice needs it to show the word being read, and the sample script lets everyone try it.
    private var usesWordStyle: Bool {
        guard let words = viewModel.scriptWords, !words.isEmpty, !words.isRightToLeft else { return false }
        if viewModel.voiceScrollEnabled { return true }
        return lyricsStyleEnabled && (manager.isPremium || manager.currentScript?.id == AppConstants.welcomeScriptID)
    }

    private var customization: TextCustomization {
        manager.currentScript?.customization ?? TextCustomization()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .opacity(manager.blurAmount)

            RoundedRectangle(cornerRadius: 18)
                .fill(.black.opacity(manager.backgroundOpacity))

            Group {
            if viewModel.isWordMode, let words = viewModel.scriptWords {
                WordTeleprompterView(
                    viewModel: viewModel,
                    words: words,
                    fontSize: manager.floatingFontSize,
                    lineHeightMultiple: 1.2,
                    textColor: .white,
                    alignment: customization.textAlignmentIndex,
                    horizontalPadding: manager.horizontalPadding,
                    topInset: 12,
                    anchor: 0,
                    upcomingOpacity: 0.55
                )
            } else {
                GeometryReader { geo in
                    scrollableText
                        .frame(width: geo.size.width)
                        .clipped()
                        .onAppear { viewModel.screenHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in viewModel.screenHeight = h }
                }
            }
            }
            // The text fades out at the edges by itself, so the fade looks the same over any
            // background, blur or transparency.
            .mask(verticalFade)
            .mask(horizontalFade)
        }
        // Drag anywhere on the prompter to move it; the corner grip resizes it.
        .overlay { WindowDragArea() }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip(cornerRadius: 18, isVisible: isHovering)
        }
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovering = hovering }
        }
        .overlay(alignment: .topTrailing) {
            if manager.capture.isRecording, let start = manager.capture.recordingStartDate {
                RecordingBadge(start: start)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        // Text size changes grow and shrink the text smoothly, as in the notch.
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: manager.floatingFontSize)
        .onChange(of: manager.currentScript?.id) { viewModel.resetToTop() }
        .onChange(of: usesWordStyle, initial: true) { _, usesWords in viewModel.setWordMode(usesWords) }
    }

    // MARK: - Edge fades

    private var verticalFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 30)
        }
    }

    /// Inside the side margins, so it only softens text that reaches into them.
    private var horizontalFade: some View {
        let width = min(28, max(8, manager.horizontalPadding * 0.6))
        return HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: width)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: width)
        }
    }

    // MARK: - Scrolling text

    private func normalizedText(from input: AttributedString) -> AttributedString {
        var result = input
        for run in result.runs {
            guard let font = run.font else { continue }
            let isBold: Bool, isItalic: Bool
            if #available(macOS 26.0, *) {
                let resolved = font.resolve(in: fontContext)
                (isBold, isItalic) = (resolved.isBold, resolved.isItalic)
            } else {
                (isBold, isItalic) = font.ypEditorTraits
            }
            var scaled = Font.system(size: manager.floatingFontSize)
            if isBold { scaled = scaled.bold() }
            if isItalic { scaled = scaled.italic() }
            result[run.range].font = scaled
        }
        return result
    }

    private var scrollableText: some View {
        let raw: AttributedString
        if manager.currentScript == nil {
            raw = AttributedString("[ No script — pick one from the menu bar ]")
        } else if (manager.currentScript?.content ?? "").isEmpty {
            raw = AttributedString("[ Script is empty — add content in the editor ]")
        } else {
            raw = manager.currentScript?.attributedContent ?? AttributedString()
        }
        let displayText = normalizedText(from: raw)
        let content = manager.currentScript?.content ?? ""
        return Text(displayText)
            .font(readingFont.resolved(for: content).font(size: manager.floatingFontSize))
            .tracking(letterSpacing.tracking(for: manager.floatingFontSize, in: content))
            .foregroundStyle(.white)
            .multilineTextAlignment(customization.textAlignmentIndex.textAlignment)
            .lineSpacing(4)
            .padding(.horizontal, manager.horizontalPadding)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: customization.textAlignmentIndex.frameAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear {
                            viewModel.contentHeight = g.size.height
                            viewModel.restoreClassicPositionIfNeeded()
                        }
                        .onChange(of: g.size.height) { _, h in viewModel.contentHeight = h }
                }
            )
            .offset(y: -viewModel.contentOffset)
    }
}
#endif
