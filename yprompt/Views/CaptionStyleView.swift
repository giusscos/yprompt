//
//  CaptionStyleView.swift
//  yprompt
//

#if os(iOS) || os(macOS)
import SwiftUI

/// The captions' font, size, position, colors and background, above a sample drawn by the
/// same renderer the saved video uses. Every change shows on the video straight away too.
struct CaptionStyleView: View {
    @Bindable var model: RecordingEditorModel
    @Environment(\.dismiss) private var dismiss

    private var look: Binding<CaptionLook> {
        Binding(get: { model.recording.look }, set: { model.setCaptionLook($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Caption Style")
                    .font(.headline)
                Spacer()
                #if os(iOS)
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sample
                    section("Font") { fontPicker }
                    section("Size") {
                        Picker("Size", selection: look.size) {
                            ForEach(CaptionSize.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    section("Position") {
                        Picker("Position", selection: Binding(get: { model.recording.captionPosition },
                                                              set: { model.setCaptionPosition($0) })) {
                            ForEach(CaptionPosition.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    section("Text") { CaptionColorRow(selection: look.textColor) }
                    if model.recording.captionStyle == .lyrics {
                        section("Highlight", footer: "The word being said.") {
                            CaptionColorRow(selection: look.highlightColor)
                        }
                    }
                    section("Background") {
                        Picker("Background", selection: look.background.animation(.snappy)) {
                            ForEach(CaptionBackground.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if model.recording.look.background != .none {
                        section(model.recording.look.background == .outline ? "Outline Color" : "Box Color") {
                            CaptionColorRow(selection: look.backgroundColor)
                        }
                        .transition(.opacity)
                    }
                    Toggle("All Caps", isOn: look.allCaps)
                        .tint(.accentColor)
                    Button("Reset Style") {
                        withAnimation(.snappy) { model.setCaptionLook(CaptionLook()) }
                    }
                    .disabled(model.recording.look == CaptionLook())
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 340, height: 600)
        #else
        .frame(minWidth: 320, idealWidth: 380, minHeight: 440, idealHeight: 640)
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(white: 0.09))
        #endif
    }

    private func section<Content: View>(_ title: LocalizedStringKey, footer: LocalizedStringKey? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fontPicker: some View {
        HStack(spacing: 8) {
            ForEach(CaptionFont.allCases) { font in
                let isSelected = model.recording.look.font == font
                Button { look.wrappedValue.font = font } label: {
                    VStack(spacing: 4) {
                        Text(verbatim: "Aa")
                            .font(.system(size: 22, weight: .heavy, design: font.design))
                        Text(font.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(isSelected ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(font.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: Sample

    /// The caption under the playhead (or the first one) over the frame there, as it will be saved.
    private var sample: some View {
        let size = model.renderSize.width > 0 ? model.renderSize : CGSize(width: 1080, height: 1920)
        let line = sampleLine
        let style: CaptionStyle = model.recording.captionStyle == .off ? .clean : model.recording.captionStyle
        let renderer = CaptionRenderer(lines: [line], style: style, position: .middle,
                                       look: model.recording.look, size: size)
        // The second word being said: shows the highlight, with lit words before and dim ones after.
        let time = (line.words.count > 1 ? line.words[1].start : line.start) + 0.35
        let caption = renderer.image(at: time)
        return GeometryReader { geometry in
            let scale = geometry.size.width / size.width
            ZStack {
                backdrop
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                if let caption {
                    Image(decorative: caption.image, scale: 1)
                        .resizable()
                        .frame(width: CGFloat(caption.image.width) * scale,
                               height: CGFloat(caption.image.height) * scale)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let frame = currentFrame {
            Image(decorative: frame, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var currentFrame: CGImage? {
        guard let location = model.editList.location(at: model.currentTime),
              let piece = model.recording.pieces.first(where: { $0.id == location.pieceID }) else { return nil }
        return model.filmstrips[piece.file]?.frame(at: location.source)
    }

    /// A few words from the recording's own captions, timed evenly for the sample: the caption
    /// under the playhead, or the first with a few words, so the highlight has neighbours.
    private var sampleLine: CaptionLine {
        let source = [model.currentLine].compactMap { $0 }.first { $0.words.count >= 3 }
            ?? model.captionLines.first { $0.words.count >= 3 }
            ?? model.currentLine
            ?? model.captionLines.first
        var words = Array((source?.words ?? []).prefix(6))
        if words.isEmpty {
            words = String(localized: "This is how your captions will look")
                .split(separator: " ")
                .map { CaptionWord(text: String($0), start: 0, end: 0) }
        }
        for index in words.indices {
            words[index].start = Double(index) * 0.4
            words[index].end = Double(index) * 0.4 + 0.35
        }
        return CaptionLine(words: words, start: 0, end: Double(words.count) * 0.4 + 1)
    }
}

/// A row of color swatches.
private struct CaptionColorRow: View {
    @Binding var selection: CaptionColor

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CaptionColor.allCases) { color in
                let isSelected = selection == color
                Button { selection = color } label: {
                    Circle()
                        .fill(Color(cgColor: color.cgColor()))
                        .overlay { Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1) }
                        .frame(width: 26, height: 26)
                        .padding(4)
                        .overlay {
                            Circle()
                                .strokeBorder(.white, lineWidth: 2)
                                .opacity(isSelected ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(color.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

private extension CaptionFont {
    var design: Font.Design {
        switch self {
        case .rounded: .rounded
        case .classic: .default
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}
#endif
