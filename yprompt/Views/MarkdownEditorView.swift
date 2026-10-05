//
//  MarkdownEditorView.swift
//  yprompt
//

import SwiftUI

enum TextFormat {
    case bold, italic, underline, strikethrough
}

/// Script editor. Rich text with formatting on iOS / macOS 26 and later;
/// plain text on older systems, where `TextEditor` has no attributed-text selection.
struct MarkdownEditorView: View {
    @Binding var text: AttributedString
    /// Set by the host (e.g. the macOS toolbar) to format the current selection; cleared once applied.
    @Binding var formatRequest: TextFormat?

    static var supportsFormatting: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { true } else { false }
    }

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            RichTextEditor(text: $text, formatRequest: $formatRequest)
        } else {
            PlainTextEditor(text: $text)
        }
    }
}

// MARK: - Rich text (iOS / macOS 26+)

@available(iOS 26.0, macOS 26.0, *)
private struct RichTextEditor: View {
    @Binding var text: AttributedString
    @Binding var formatRequest: TextFormat?

    @State private var selection = AttributedTextSelection()
    @Environment(\.fontResolutionContext) private var fontContext
    @FocusState private var isFocused: Bool

    // MARK: - Active state

    private var typingFont: Font {
        selection.typingAttributes(in: text).font ?? .default
    }

    private var isBold: Bool {
        typingFont.resolve(in: fontContext).isBold
    }
    private var isItalic: Bool {
        typingFont.resolve(in: fontContext).isItalic
    }
    private var isUnderline: Bool {
        selection.typingAttributes(in: text).underlineStyle != nil
    }
    private var isStrikethrough: Bool {
        selection.typingAttributes(in: text).strikethroughStyle != nil
    }

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .font(.body)
            .focused($isFocused)
            .onChange(of: formatRequest) { _, format in
                guard let format else { return }
                apply(format)
                formatRequest = nil
            }
            #if os(iOS)
            .toolbar { keyboardToolbar }
            #endif
    }

    // MARK: - Formatting

    private func apply(_ format: TextFormat) {
        switch format {
        case .bold:
            let newBold = !isBold
            text.transformAttributes(in: &selection) { container in
                container.font = (container.font ?? .body).bold(newBold)
            }
        case .italic:
            let newItalic = !isItalic
            text.transformAttributes(in: &selection) { container in
                container.font = (container.font ?? .body).italic(newItalic)
            }
        case .underline:
            let newStyle: Text.LineStyle? = isUnderline ? nil : Text.LineStyle(pattern: .solid)
            text.transformAttributes(in: &selection) { container in
                container.underlineStyle = newStyle
            }
        case .strikethrough:
            let newStyle: Text.LineStyle? = isStrikethrough ? nil : Text.LineStyle(pattern: .solid)
            text.transformAttributes(in: &selection) { container in
                container.strikethroughStyle = newStyle
            }
        }
    }

    // MARK: - iOS Keyboard Toolbar (`.keyboard` placement unavailable on visionOS)

    #if os(iOS)
    @ToolbarContentBuilder
    private var keyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            formatButton("bold",          isActive: isBold)          { apply(.bold) }
            formatButton("italic",        isActive: isItalic)        { apply(.italic) }
            formatButton("underline",     isActive: isUnderline)     { apply(.underline) }
            formatButton("strikethrough", isActive: isStrikethrough) { apply(.strikethrough) }
            Spacer()
            Button {
                isFocused = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatButton(
        _ systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .fontWeight(isActive ? .semibold : .regular)
        }
        .tint(isActive ? Color.accentColor : Color.primary)
    }
    #endif
}

// MARK: - Plain text (older systems)

private struct PlainTextEditor: View {
    @Binding var text: AttributedString
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: Binding(
            get: { String(text.characters) },
            set: { text = AttributedString($0) }
        ))
        .font(.body)
        .focused($isFocused)
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    isFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .foregroundStyle(.secondary)
                }
            }
        }
        #endif
    }
}
