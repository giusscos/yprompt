//
//  MarkdownEditorView.swift
//  yprompt
//

import SwiftUI

struct MarkdownEditorView: View {
    @Binding var text: AttributedString
    @Binding var selection: AttributedTextSelection

    var onBold: () -> Void
    var onItalic: () -> Void
    var onUnderline: () -> Void
    var onStrikethrough: () -> Void

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
            #if os(iOS)
            .toolbar { keyboardToolbar }
            #endif
    }

    // MARK: - iOS Keyboard Toolbar

    #if os(iOS)
    @ToolbarContentBuilder
    private var keyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            formatButton("bold",          isActive: isBold,          action: onBold)
            formatButton("italic",        isActive: isItalic,        action: onItalic)
            formatButton("underline",     isActive: isUnderline,     action: onUnderline)
            formatButton("strikethrough", isActive: isStrikethrough, action: onStrikethrough)
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
