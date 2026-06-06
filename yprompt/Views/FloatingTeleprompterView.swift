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

            GeometryReader { geo in
                scrollableText
                    .frame(width: geo.size.width)
                    .clipped()
                    .onAppear { viewModel.screenHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in viewModel.screenHeight = h }
            }

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
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onChange(of: manager.currentScript?.id) { viewModel.resetToTop() }
    }

    // MARK: - Scrolling text

    private func normalizedText(from input: AttributedString) -> AttributedString {
        var result = input
        for run in result.runs {
            guard let font = run.font else { continue }
            let resolved = font.resolve(in: fontContext)
            var scaled = Font.system(size: manager.floatingFontSize)
            if resolved.isBold { scaled = scaled.bold() }
            if resolved.isItalic { scaled = scaled.italic() }
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
        return Text(displayText)
            .font(.system(size: manager.floatingFontSize))
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
                        .onAppear { viewModel.contentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in viewModel.contentHeight = h }
                }
            )
            .offset(y: -viewModel.contentOffset)
    }
}
#endif
