//
//  MarkdownEditorView.swift
//  yprompt
//

import SwiftUI

enum TextFormat {
    case bold, italic, underline, strikethrough
}

/// Script editor on the Mac (and Vision Pro), with bold, italic, underline and strikethrough:
/// SwiftUI's `TextEditor` on macOS 26 and later. Before that, where it can't format a
/// selection, the text is edited plainly, keeping the formatting already there.
/// iPhone and iPad use `ScriptTextEditor`.
struct MarkdownEditorView: View {
    @Binding var text: AttributedString
    /// Set by the host (e.g. the macOS toolbar) to format the current selection; cleared once applied.
    @Binding var formatRequest: TextFormat?
    /// Puts the cursor in the editor as soon as it appears.
    var focusOnAppear = false

    static var supportsFormatting: Bool {
        #if os(iOS)
        true
        #else
        if #available(macOS 26.0, *) { true } else { false }
        #endif
    }

    /// `-ypLegacyEditor` tries the pre-26 editor on a newer Mac.
    private static var forcesLegacy: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ypLegacyEditor")
        #else
        false
        #endif
    }

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *), !Self.forcesLegacy {
            RichTextEditor(text: $text, formatRequest: $formatRequest, focusOnAppear: focusOnAppear)
        } else {
            PlainTextEditor(text: $text, focusOnAppear: focusOnAppear)
        }
    }
}

// MARK: - Rich text (iOS / macOS 26+)

@available(iOS 26.0, macOS 26.0, *)
private struct RichTextEditor: View {
    @Binding var text: AttributedString
    @Binding var formatRequest: TextFormat?
    var focusOnAppear = false

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
            .onAppear { if focusOnAppear { isFocused = true } }
            .onChange(of: formatRequest) { _, format in
                guard let format else { return }
                apply(format)
                formatRequest = nil
            }
            #if os(macOS)
            .modifier(BelowToolbar())
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

}

// MARK: - Plain text (macOS 14 and 15)

private struct PlainTextEditor: View {
    @Binding var text: AttributedString
    var focusOnAppear = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: Binding(
            get: { String(text.characters) },
            // Only the part that changed is replaced: formatting made on another device stays.
            set: { text = text.replacingCharacters(with: $0) }
        ))
        .font(.body)
        .focused($isFocused)
        .onAppear { if focusOnAppear { isFocused = true } }
    }
}

#if os(macOS)
/// Keeps the text view from reaching under the toolbar. When it did, the toolbar's glass
/// sampled it and drew the title and buttons dark: black on black in Dark Mode.
private struct BelowToolbar: ViewModifier {
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 1)
            content
        }
    }
}
#endif

extension AttributedString {
    /// This text changed to `new` with as little replaced as possible: what's the same at the
    /// start and the end keeps its attributes, and only the middle is swapped for plain text.
    func replacingCharacters(with new: String) -> AttributedString {
        let old = Array(characters)
        let updated = Array(new)
        guard old != updated else { return self }
        var prefix = 0
        while prefix < old.count, prefix < updated.count, old[prefix] == updated[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < updated.count - prefix,
              old[old.count - 1 - suffix] == updated[updated.count - 1 - suffix] { suffix += 1 }
        var result = self
        let start = result.characters.index(result.startIndex, offsetBy: prefix)
        let end = result.characters.index(result.endIndex, offsetBy: -suffix)
        result.replaceSubrange(start..<end, with: AttributedString(String(updated[prefix..<(updated.count - suffix)])))
        return result
    }
}
