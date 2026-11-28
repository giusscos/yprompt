//
//  ScriptTextEditor.swift
//  yprompt
//

#if os(iOS)
import SwiftUI
import UIKit

/// What the screen around the script editor needs from it: whether it's being typed in,
/// whether there's something to undo, which formats are on, and ways to act on them.
@Observable
final class ScriptEditorController {
    /// The title or the script has the keyboard.
    fileprivate(set) var isEditing = false
    fileprivate(set) var canUndo = false
    /// On for the selection, or for what's typed next.
    fileprivate(set) var activeFormats: Set<TextFormat> = []
    @ObservationIgnored fileprivate weak var coordinator: ScriptTextEditor.Coordinator?

    func toggle(_ format: TextFormat) { coordinator?.toggle(format) }
    func undo() { coordinator?.undo() }
    func endEditing() { coordinator?.endEditing() }
}

/// The script editor on iPhone and iPad: the title as a heading at the top of the page, the
/// script below it with room around the lines, and bold, italic, underline and strikethrough
/// in a bar above the keyboard.
///
/// A `UITextView`, so it looks and works the same from iOS 17 on. It reads and writes the
/// same `AttributedString` as the Mac's editor (SwiftUI fonts and line styles), so a script
/// formatted on one device keeps its formatting on another.
struct ScriptTextEditor: UIViewRepresentable {
    @Binding var text: AttributedString
    @Binding var title: String
    let controller: ScriptEditorController
    /// A new script: the title gets the keyboard, then Return moves on to the script.
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ScriptPageContainer {
        let coordinator = context.coordinator
        let container = ScriptPageContainer()
        let view = container.textView
        view.delegate = coordinator
        view.backgroundColor = .clear
        view.font = ScriptTextStyle.bodyFont
        view.textColor = ScriptTextStyle.bodyColor
        // Bold, Italic and Underline in the edit menu, and ⌘B, ⌘I, ⌘U on a keyboard.
        view.allowsEditingTextAttributes = true
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.attributedText = ScriptTextStyle.nsAttributedString(from: text)
        view.typingAttributes = ScriptTextStyle.baseAttributes
        view.inputAccessoryView = coordinator.makeFormatBar()
        view.onPaste = { [weak coordinator] in coordinator?.normalizeAfterPaste() }
        view.titleField.delegate = coordinator
        view.titleField.text = ScriptTextStyle.isDefaultTitle(title) ? "" : title
        view.titleField.addTarget(coordinator, action: #selector(Coordinator.titleChanged), for: .editingChanged)
        view.updatePlaceholder()
        coordinator.textView = view
        coordinator.lastText = text
        controller.coordinator = coordinator
        if focusOnAppear {
            DispatchQueue.main.async {
                if view.titleField.text?.isEmpty == true {
                    view.titleField.becomeFirstResponder()
                } else {
                    view.becomeFirstResponder()
                }
            }
        }
        return container
    }

    func updateUIView(_ container: ScriptPageContainer, context: Context) {
        let view = container.textView
        context.coordinator.parent = self
        controller.coordinator = context.coordinator
        // A title set from outside (an imported file's name), unless it's being typed.
        if !view.titleField.isFirstResponder {
            let shown = ScriptTextStyle.isDefaultTitle(title) ? "" : title
            if view.titleField.text != shown { view.titleField.text = shown }
        }
        // Changed from outside (paste button, import): show it, keeping the cursor where it can be.
        guard text != context.coordinator.lastText else { return }
        let selection = view.selectedRange
        view.attributedText = ScriptTextStyle.nsAttributedString(from: text)
        context.coordinator.lastText = text
        let length = view.attributedText.length
        view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        view.updatePlaceholder()
        context.coordinator.refresh()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextFieldDelegate {
        var parent: ScriptTextEditor
        weak var textView: ScriptTextView?
        /// What was last sent to or received from SwiftUI, so an update that's only our own
        /// edit coming back doesn't reset the text view.
        var lastText = AttributedString()
        private var formatBar: UIHostingController<FormatBar>?

        init(_ parent: ScriptTextEditor) { self.parent = parent }

        // MARK: Script

        func textViewDidBeginEditing(_ textView: UITextView) { refreshEditing() }
        func textViewDidEndEditing(_ textView: UITextView) { refreshEditing() }

        func textViewDidChange(_ textView: UITextView) {
            send()
            refresh()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refresh()
        }

        private func send() {
            guard let textView else { return }
            let converted = ScriptTextStyle.attributedString(from: textView.attributedText)
            lastText = converted
            parent.text = converted
            textView.updatePlaceholder()
        }

        /// Pasted text keeps its bold, italic, underline and strikethrough, in the editor's own
        /// font, size and color.
        func normalizeAfterPaste() {
            guard let textView else { return }
            let selection = textView.selectedRange
            let converted = ScriptTextStyle.attributedString(from: textView.attributedText)
            textView.attributedText = ScriptTextStyle.nsAttributedString(from: converted)
            textView.selectedRange = selection
            textView.typingAttributes = ScriptTextStyle.baseAttributes
            lastText = converted
            parent.text = converted
            textView.updatePlaceholder()
            refresh()
        }

        /// The title's undo while it's being typed in, otherwise the script's.
        private var activeUndoManager: UndoManager? {
            guard let textView else { return nil }
            return textView.titleField.isFirstResponder ? textView.titleField.undoManager : textView.undoManager
        }

        func undo() {
            guard let undoManager = activeUndoManager, undoManager.canUndo else { return }
            undoManager.undo()
            if textView?.titleField.isFirstResponder == true { titleChanged() } else { send() }
            refresh()
        }

        func endEditing() {
            textView?.titleField.resignFirstResponder()
            textView?.resignFirstResponder()
        }

        // MARK: Title

        @objc func titleChanged() {
            guard let text = textView?.titleField.text else { return }
            // An empty title isn't kept: the script keeps its name until a new one is typed.
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { parent.title = text }
            refresh()
        }

        func textFieldDidBeginEditing(_ textField: UITextField) { refreshEditing() }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if textField.text?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                textField.text = ScriptTextStyle.isDefaultTitle(parent.title) ? "" : parent.title
            }
            refreshEditing()
        }

        /// Return goes on to the script, at its start.
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard let textView else { return true }
            textView.becomeFirstResponder()
            textView.selectedRange = NSRange(location: 0, length: 0)
            return false
        }

        // MARK: State

        /// After the keyboard has moved between the title and the script, so neither end
        /// reads as "not editing" for a moment.
        private func refreshEditing() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView else { return }
                let editing = textView.isFirstResponder || textView.titleField.isFirstResponder
                if parent.controller.isEditing != editing { parent.controller.isEditing = editing }
                refresh()
            }
        }

        func refresh() {
            guard let textView else { return }
            let controller = parent.controller
            let formats = Set(TextFormat.allCases.filter(isActive))
            if controller.activeFormats != formats { controller.activeFormats = formats }
            let canUndo = activeUndoManager?.canUndo ?? false
            if controller.canUndo != canUndo { controller.canUndo = canUndo }
        }

        // MARK: Formatting

        func toggle(_ format: TextFormat) {
            guard let textView else { return }
            let range = textView.selectedRange
            if range.length == 0 {
                // Nothing selected: what's typed next.
                let isOn = Self.has(format, in: textView.typingAttributes)
                textView.typingAttributes = Self.setting(format, on: !isOn, in: textView.typingAttributes)
            } else {
                let isOn = isActive(format)
                let storage = textView.textStorage
                storage.beginEditing()
                storage.enumerateAttributes(in: range) { attributes, part, _ in
                    storage.setAttributes(Self.setting(format, on: !isOn, in: attributes), range: part)
                }
                storage.endEditing()
                textView.selectedRange = range
                send()
            }
            refresh()
        }

        /// On for the whole selection, or for what's typed next when nothing is selected.
        private func isActive(_ format: TextFormat) -> Bool {
            guard let textView else { return false }
            let range = textView.selectedRange
            guard range.length > 0 else { return Self.has(format, in: textView.typingAttributes) }
            var all = true
            textView.attributedText.enumerateAttributes(in: range) { attributes, _, stop in
                if !Self.has(format, in: attributes) { all = false; stop.pointee = true }
            }
            return all
        }

        private static func has(_ format: TextFormat, in attributes: [NSAttributedString.Key: Any]) -> Bool {
            let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            switch format {
            case .bold: return traits.contains(.traitBold)
            case .italic: return traits.contains(.traitItalic)
            case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
            case .strikethrough: return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            }
        }

        private static func setting(_ format: TextFormat, on: Bool,
                                    in attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var attributes = attributes
            switch format {
            case .bold, .italic:
                let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
                var bold = traits.contains(.traitBold)
                var italic = traits.contains(.traitItalic)
                if format == .bold { bold = on } else { italic = on }
                attributes[.font] = ScriptTextStyle.font(bold: bold, italic: italic)
            case .underline:
                attributes[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
            case .strikethrough:
                attributes[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil
            }
            attributes[.foregroundColor] = ScriptTextStyle.bodyColor
            attributes[.paragraphStyle] = ScriptTextStyle.paragraphStyle
            return attributes
        }

        // MARK: Format bar

        func makeFormatBar() -> UIView {
            let host = UIHostingController(rootView: FormatBar(controller: parent.controller))
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            host.view.frame = CGRect(x: 0, y: 0, width: 320, height: FormatBar.height)
            host.view.autoresizingMask = [.flexibleWidth]
            formatBar = host
            return host.view
        }
    }
}

/// Bold, italic, underline and strikethrough above the keyboard, in one bar; what's on is
/// filled with the accent color.
struct FormatBar: View {
    static let height: CGFloat = 64
    let controller: ScriptEditorController

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TextFormat.allCases, id: \.self) { format in
                let isOn = controller.activeFormats.contains(format)
                Button { controller.toggle(format) } label: {
                    Image(systemName: format.symbol)
                        .font(.system(size: 18, weight: isOn ? .bold : .medium))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .frame(width: 42, height: 42)
                        .background {
                            if isOn { Circle().fill(Color.accentColor) }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(format.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(5)
        .ypGlassEffect(cornerRadius: 26)
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.2), value: controller.activeFormats)
    }
}

extension TextFormat: CaseIterable {
    static var allCases: [TextFormat] { [.bold, .italic, .underline, .strikethrough] }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        }
    }
}

/// The script's page: the title field at the top of the scrolling content, the script under
/// it with margins that keep lines a readable length, and a placeholder while it's empty.
final class ScriptTextView: UITextView {
    let titleField = UITextField()
    private let placeholder = UILabel()
    var onPaste: (() -> Void)?

    /// Past this the margins grow, so lines stay easy to follow on an iPad.
    private static let maxTextWidth: CGFloat = 680
    private static let topPadding: CGFloat = 12
    private static let titleGap: CGFloat = 10

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        titleField.font = ScriptTextStyle.titleFont
        titleField.adjustsFontForContentSizeCategory = true
        titleField.textColor = .label
        titleField.placeholder = String(localized: "Title")
        titleField.returnKeyType = .next
        titleField.adjustsFontSizeToFitWidth = true
        titleField.minimumFontSize = 20
        titleField.autocapitalizationType = .sentences
        titleField.accessibilityLabel = String(localized: "Title")
        // Formatting is for the script: without its own (empty) accessory the title would get
        // the script's format bar, as the keyboard asks up the chain of views.
        titleField.inputAccessoryView = UIView(frame: .zero)

        placeholder.text = String(localized: "Type or paste your script here…")
        placeholder.font = ScriptTextStyle.bodyFont
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = max(24, (bounds.width - Self.maxTextWidth) / 2)
        let width = max(0, bounds.width - side * 2)
        let titleHeight = ceil((titleField.font?.lineHeight ?? 41) + 8)
        // The title lives beside the text view (see `ScriptPageContainer`) and moves with its
        // scrolling, as if it were the first line of the page. This runs on every scroll.
        titleField.frame = CGRect(x: frame.minX + side, y: frame.minY + Self.topPadding - contentOffset.y,
                                  width: width, height: titleHeight)

        let padding = textContainer.lineFragmentPadding
        let inset = UIEdgeInsets(top: Self.topPadding + titleHeight + Self.titleGap, left: side - padding,
                                 bottom: 48, right: side - padding)
        if textContainerInset != inset { textContainerInset = inset }
        let size = placeholder.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholder.frame = CGRect(x: side, y: inset.top, width: width, height: size.height)
    }

    func updatePlaceholder() {
        placeholder.isHidden = !attributedText.string.isEmpty
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        onPaste?()
    }
}

/// The text view and, above it, the title field. The title isn't a subview of the text view:
/// a text view is a single accessibility element, so VoiceOver couldn't reach a field inside it.
final class ScriptPageContainer: UIView {
    let textView = ScriptTextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        textView.frame = bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(textView)
        addSubview(textView.titleField)
        accessibilityElements = [textView.titleField, textView]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The script page's type, and the way between the script's `AttributedString` (SwiftUI fonts
/// and line styles) and the text view's `NSAttributedString`. Only bold, italic, underline and
/// strikethrough cross over: every other attribute is the editor's own.
enum ScriptTextStyle {
    private typealias FontKey = AttributeScopes.SwiftUIAttributes.FontAttribute
    private typealias UnderlineKey = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
    private typealias StrikethroughKey = AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute

    /// A little larger than body text, and following the reader's text size.
    static var bodyFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 19))
    }

    static var titleFont: UIFont {
        UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 32, weight: .bold))
    }

    /// Softer than the title, so the heading stands out.
    static let bodyColor = UIColor.label.withAlphaComponent(0.82)

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = bodyFont.pointSize * 0.42
        return style
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: bodyColor, .paragraphStyle: paragraphStyle]
    }

    /// The name a new script starts with, shown as an empty title with a placeholder.
    static func isDefaultTitle(_ title: String) -> Bool {
        title == "Untitled Script" || title == String(localized: "Untitled Script")
    }

    static func font(bold: Bool, italic: Bool) -> UIFont {
        let base = bodyFont
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: 0)
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
            let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let bold = traits.contains(.traitBold)
            let italic = traits.contains(.traitItalic)
            // The same fonts the Mac's editor sets, which `ypEditorTraits` reads back.
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
