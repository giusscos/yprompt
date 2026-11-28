//
//  MacScriptTextEditor.swift
//  yprompt
//

#if os(macOS)
import AppKit
import SwiftUI

/// The script editor on the Mac, laid out like the iPhone's: the title as a heading at the top
/// of the page, the script under it with room around the lines, and the text kept to a
/// readable width however wide the window is.
///
/// An `NSTextView`, so bold, italic, underline and strikethrough work on every macOS version
/// (from the toolbar, or ⌘B, ⌘I, ⌘U). It reads and writes the same `AttributedString` as
/// the iPhone's editor, so formatting crosses between devices.
struct MacScriptTextEditor: NSViewRepresentable {
    @Binding var text: AttributedString
    @Binding var title: String
    /// Set by the toolbar to format the selection; cleared once applied.
    @Binding var formatRequest: TextFormat?
    /// A new script: the title gets the cursor.
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = MacScriptPageView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textStorage?.setAttributedString(MacScriptTextStyle.nsAttributedString(from: text))
        textView.typingAttributes = MacScriptTextStyle.baseAttributes
        textView.delegate = coordinator
        textView.onFormat = { [weak coordinator] format in coordinator?.toggle(format) }
        textView.onPaste = { [weak coordinator] in coordinator?.normalizeAfterPaste() }
        textView.titleField.delegate = coordinator
        textView.titleField.stringValue = MacScriptTextStyle.isDefaultTitle(title) ? "" : title
        textView.updatePlaceholder()
        scrollView.documentView = textView

        coordinator.textView = textView
        coordinator.lastText = text
        if focusOnAppear {
            DispatchQueue.main.async {
                let target: NSView = textView.titleField.stringValue.isEmpty ? textView.titleField : textView
                textView.window?.makeFirstResponder(target)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if let format = formatRequest {
            DispatchQueue.main.async {
                coordinator.toggle(format)
                formatRequest = nil
            }
        }
        // A title set from outside (Rename, an imported file's name), unless it's being typed.
        if textView.window?.firstResponder !== textView.titleField.currentEditor() {
            let shown = MacScriptTextStyle.isDefaultTitle(title) ? "" : title
            if textView.titleField.stringValue != shown { textView.titleField.stringValue = shown }
        }
        // Changed from outside (paste button, import): show it, keeping the cursor where it can be.
        guard text != coordinator.lastText else { return }
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(MacScriptTextStyle.nsAttributedString(from: text))
        coordinator.lastText = text
        let length = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        textView.updatePlaceholder()
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
        var parent: MacScriptTextEditor
        weak var textView: MacScriptPageView?
        /// What was last sent to or received from SwiftUI, so our own edit coming back
        /// doesn't reset the text view.
        var lastText = AttributedString()

        init(_ parent: MacScriptTextEditor) { self.parent = parent }

        // MARK: Script

        func textDidChange(_ notification: Notification) {
            send()
        }

        private func send() {
            guard let textView, let storage = textView.textStorage else { return }
            let converted = MacScriptTextStyle.attributedString(from: storage)
            lastText = converted
            parent.text = converted
            textView.updatePlaceholder()
        }

        /// Pasted text keeps its bold, italic, underline and strikethrough, in the editor's own
        /// font, size and color.
        func normalizeAfterPaste() {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let converted = MacScriptTextStyle.attributedString(from: storage)
            storage.setAttributedString(MacScriptTextStyle.nsAttributedString(from: converted))
            textView.setSelectedRange(selection)
            textView.typingAttributes = MacScriptTextStyle.baseAttributes
            lastText = converted
            parent.text = converted
            textView.updatePlaceholder()
        }

        // MARK: Title

        func controlTextDidChange(_ notification: Notification) {
            guard let value = textView?.titleField.stringValue else { return }
            // An empty title isn't kept: the script keeps its name until a new one is typed.
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { parent.title = value }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = textView?.titleField else { return }
            if field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                field.stringValue = MacScriptTextStyle.isDefaultTitle(parent.title) ? "" : parent.title
            }
        }

        /// Return in the title goes on to the script, at its start.
        func control(_ control: NSControl, textView fieldEditor: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let textView else { return false }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            return true
        }

        // MARK: Formatting

        func toggle(_ format: TextFormat) {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            if range.length == 0 {
                // Nothing selected: what's typed next.
                let isOn = Self.has(format, in: textView.typingAttributes)
                textView.typingAttributes = Self.setting(format, on: !isOn, in: textView.typingAttributes)
                return
            }
            var all = true
            storage.enumerateAttributes(in: range) { attributes, _, stop in
                if !Self.has(format, in: attributes) { all = false; stop.pointee = true }
            }
            // Through the text view, so the change can be undone.
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()
            storage.enumerateAttributes(in: range) { attributes, part, _ in
                storage.setAttributes(Self.setting(format, on: !all, in: attributes), range: part)
            }
            storage.endEditing()
            textView.didChangeText()
            textView.setSelectedRange(range)
        }

        private static func has(_ format: TextFormat, in attributes: [NSAttributedString.Key: Any]) -> Bool {
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            switch format {
            case .bold: return traits.contains(.bold)
            case .italic: return traits.contains(.italic)
            case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
            case .strikethrough: return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            }
        }

        private static func setting(_ format: TextFormat, on: Bool,
                                    in attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var attributes = attributes
            switch format {
            case .bold, .italic:
                let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                var bold = traits.contains(.bold)
                var italic = traits.contains(.italic)
                if format == .bold { bold = on } else { italic = on }
                attributes[.font] = MacScriptTextStyle.font(bold: bold, italic: italic)
            case .underline:
                attributes[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
            case .strikethrough:
                attributes[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil
            }
            attributes[.foregroundColor] = MacScriptTextStyle.bodyColor
            attributes[.paragraphStyle] = MacScriptTextStyle.paragraphStyle
            return attributes
        }
    }
}

/// The script's page: the title field at the top of the scrolling text, margins that keep the
/// lines a readable length, and a placeholder while the script is empty.
final class MacScriptPageView: NSTextView {
    let titleField = NSTextField()
    private let placeholder = NSTextField(labelWithString: String(localized: "Type or paste your script here…"))
    var onFormat: ((TextFormat) -> Void)?
    var onPaste: (() -> Void)?

    /// Past this the margins grow, so lines stay easy to follow in a wide window.
    private static let maxTextWidth: CGFloat = 680
    private static let topPadding: CGFloat = 28
    private static let titleGap: CGFloat = 12

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setUp()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.font = MacScriptTextStyle.titleFont
        titleField.textColor = .labelColor
        titleField.placeholderString = String(localized: "Title")
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.setAccessibilityLabel(String(localized: "Title"))
        addSubview(titleField)

        placeholder.font = MacScriptTextStyle.bodyFont
        placeholder.textColor = .placeholderTextColor
        placeholder.setAccessibilityElement(false)
        addSubview(placeholder)
        layoutPage()
    }

    private var titleHeight: CGFloat {
        ceil(titleField.intrinsicContentSize.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPage()
    }

    /// The margins for this width, and the title and placeholder where the text starts.
    private func layoutPage() {
        let side = max(40, (bounds.width - Self.maxTextWidth) / 2)
        let inset = NSSize(width: side, height: Self.topPadding + titleHeight + Self.titleGap)
        if textContainerInset != inset { textContainerInset = inset }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let width = max(0, bounds.width - side * 2 - padding * 2)
        // Flipped: y grows downward from the top of the page.
        titleField.frame = NSRect(x: side + padding - 2, y: Self.topPadding, width: width + 4, height: titleHeight)
        let placeholderHeight = ceil(placeholder.intrinsicContentSize.height)
        placeholder.frame = NSRect(x: side + padding, y: inset.height, width: width, height: placeholderHeight)
    }

    func updatePlaceholder() {
        placeholder.isHidden = !string.isEmpty
    }

    /// The title is drawn inside the text view; listed here so VoiceOver can reach it.
    override func accessibilityChildren() -> [Any]? {
        [titleField] + (super.accessibilityChildren() ?? [])
    }

    /// ⌘B, ⌘I and ⌘U, which the app has no Format menu for.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "b": onFormat?(.bold); return true
        case "i": onFormat?(.italic); return true
        case "u": onFormat?(.underline); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        onPaste?()
    }
}

/// The Mac page's type, and the way between the script's `AttributedString` (SwiftUI fonts and
/// line styles) and the text view's `NSAttributedString`. Only bold, italic, underline and
/// strikethrough cross over.
enum MacScriptTextStyle {
    private typealias FontKey = AttributeScopes.SwiftUIAttributes.FontAttribute
    private typealias UnderlineKey = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
    private typealias StrikethroughKey = AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute

    static var bodyFont: NSFont { .systemFont(ofSize: 16) }
    static var titleFont: NSFont { .systemFont(ofSize: 28, weight: .bold) }
    /// Softer than the title, so the heading stands out.
    static var bodyColor: NSColor { NSColor.labelColor.withAlphaComponent(0.85) }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = bodyFont.pointSize * 0.42
        return style
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: bodyColor, .paragraphStyle: paragraphStyle]
    }

    static func isDefaultTitle(_ title: String) -> Bool {
        title == "Untitled Script" || title == String(localized: "Untitled Script")
    }

    static func font(bold: Bool, italic: Bool) -> NSFont {
        var font = bodyFont
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static func nsAttributedString(from text: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = baseAttributes
        for run in text.runs {
            let string = String(text[run.range].characters)
            guard !string.isEmpty else { continue }
            let traits = run[FontKey.self]?.ypEditorTraits ?? (isBold: false, isItalic: false)
            var attributes = base
            attributes[.font] = font(bold: traits.isBold, italic: traits.isItalic)
            if run[UnderlineKey.self] != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run[StrikethroughKey.self] != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        return result
    }

    static func attributedString(from text: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var part = AttributedString(text.attributedSubstring(from: range).string)
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)
            // The same fonts the iPhone's editor sets, which `ypEditorTraits` reads back.
            if bold && italic {
                part[FontKey.self] = Font.body.bold().italic()
            } else if bold {
                part[FontKey.self] = Font.body.bold()
            } else if italic {
                part[FontKey.self] = Font.body.italic()
            }
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 {
                part[UnderlineKey.self] = Text.LineStyle(pattern: .solid)
            }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 {
                part[StrikethroughKey.self] = Text.LineStyle(pattern: .solid)
            }
            result.append(part)
        }
        return result
    }
}
#endif
