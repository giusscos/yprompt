//
//  EditorView.swift
//  yprompt
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit

// MARK: - Rich Text FileDocument

private struct RichTextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.rtf] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - EditorView

struct EditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(StoreKitService.self) private var storeKit
    @Bindable var script: Script

    @State private var attrText = AttributedString()
    @State private var selection = AttributedTextSelection()

    @State private var showingCustomization = false
    @State private var isSaving = false
    @State private var showingImporter = false
    @State private var showingRTFExporter = false
    @State private var rtfDocument: RichTextFile? = nil
    @State private var showingRename = false
    @State private var renameText = ""
    
    @State private var saveTask: Task<Void, Never>?
    @State private var cachedRTFData = Data()
    @State private var isLoaded = false
    #if os(iOS)
    @State private var showingTeleprompter = false
    #endif

    private var rtfFilename: String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let clean = script.title
            .components(separatedBy: unsafe)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return "\(clean.isEmpty ? "Untitled" : clean).rtf"
    }

    private var wordCount: Int {
        script.content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }

    private var readTimeMinutes: Int {
        max(1, Int((Double(wordCount) / 130.0).rounded(.up)))
    }

    var body: some View {
        editorArea
            #if os(iOS)
            .navigationTitle(script.title)
            .navigationBarTitleDisplayMode(.inline)
            #else
            // Set macOS window title directly — avoids the always-black auto-title in the toolbar
            .onAppear { NSApp.mainWindow?.title = script.title }
            .onChange(of: script.title) { _, new in NSApp.mainWindow?.title = new }
            #endif
            .toolbar { toolbarItems }
            #if os(iOS)
            .navigationDestination(isPresented: $showingTeleprompter) {
                TeleprompterView(script: script)
                    .environment(storeKit)
            }
            #endif
            .sheet(isPresented: $showingCustomization) {
                CustomizationView(script: script)
                    .environment(storeKit)
            }
            
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.plainText, .pdf, .rtf],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    importFile(from: url)
                }
            }
            #if os(iOS)
            .fileExporter(
                isPresented: $showingRTFExporter,
                document: rtfDocument,
                contentType: .rtf,
                defaultFilename: rtfFilename
            ) { _ in
                rtfDocument = nil
            }
            #endif
            .alert("Rename Script", isPresented: $showingRename) {
                TextField("Title", text: $renameText)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                isLoaded = false
                let content = script.attributedContent
                attrText = content
                cachedRTFData = makeRTFData(from: content)
                Task { @MainActor in isLoaded = true }
            }
            .onChange(of: script.id) { _, _ in
                isLoaded = false
                let content = script.attributedContent
                attrText = content
                cachedRTFData = makeRTFData(from: content)
                Task { @MainActor in isLoaded = true }
            }
            .onChange(of: attrText) { _, newValue in
                guard isLoaded else { return }
                script.content = String(newValue.characters)
                scheduleSave(attributedText: newValue)
                cachedRTFData = makeRTFData(from: newValue)
            }
    }

    // MARK: - Editor Area

    private var editorArea: some View {
        MarkdownEditorView(
            text: $attrText,
            selection: $selection,
            onBold: applyBold,
            onItalic: applyItalic,
            onUnderline: applyUnderline,
            onStrikethrough: applyStrikethrough
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            wordCountBar
        }
    }

    private var wordCountBar: some View {
        HStack {
            Spacer()
            Group {
                if wordCount == 0 {
                    Text("Empty script")
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(wordCount) word\(wordCount == 1 ? "" : "s")  ·  ~\(readTimeMinutes) min")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2.monospacedDigit())
            Spacer()
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Navigation Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        #if os(macOS)
        // Play + formatting in one group — no gap between them
        ToolbarItemGroup(placement: .automatic) {
            Button {
                FloatingTeleprompterManager.shared.show(script: script, storeKit: storeKit)
            } label: {
                Label("Present", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(script.content.isEmpty)

            Button { applyBold() } label: { Label("Bold", systemImage: "bold") }
            Button { applyItalic() } label: { Label("Italic", systemImage: "italic") }
            Button { applyUnderline() } label: { Label("Underline", systemImage: "underline") }
            Button { applyStrikethrough() } label: { Label("Strikethrough", systemImage: "strikethrough") }
        }

        // Secondary group 1: Rename + Customize
        ToolbarItemGroup(placement: .automatic) {
            Button {
                renameText = script.title
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button { showingCustomization = true } label: {
                Label("Customize", systemImage: "paintpalette")
            }
        }

        // Secondary group 2: Import + Export
        ToolbarItemGroup(placement: .automatic) {
            Button { showingImporter = true } label: {
                Label("Import File", systemImage: "square.and.arrow.down")
            }
            Button { showRTFExporter() } label: {
                Label("Export Rich Text", systemImage: "square.and.arrow.up")
            }
            .disabled(script.content.isEmpty)
        }
        #else
        // iOS: Play button — hide tab bar with a slide-down before pushing play mode
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                TabBarAnimator.setHidden(true, animated: true)
                showingTeleprompter = true
            } label: {
                Label("Present", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(script.content.isEmpty)
        }

        // iOS: More menu — group 1: Rename + Customize
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    renameText = script.title
                    showingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                
                Button { showingCustomization = true } label: {
                    Label("Customize", systemImage: "paintpalette")
                }
                
                Divider()
                
                Button { showingImporter = true } label: {
                    Label("Import File", systemImage: "square.and.arrow.down")
                }
                
                Button {
                    rtfDocument = RichTextFile(data: cachedRTFData)
                    showingRTFExporter = true
                } label: {
                    Label("Export Rich Text", systemImage: "square.and.arrow.up")
                }
                .disabled(script.content.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        #endif
    }

    // MARK: - Rename

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        script.title = trimmed
        scheduleSave(attributedText: attrText)
    }

    // MARK: - Formatting

    private var isSelectionBold: Bool {
        let font = selection.typingAttributes(in: attrText).font ?? .default
        return font.resolve(in: fontContext).isBold
    }
    private var isSelectionItalic: Bool {
        let font = selection.typingAttributes(in: attrText).font ?? .default
        return font.resolve(in: fontContext).isItalic
    }
    private var isSelectionUnderline: Bool {
        selection.typingAttributes(in: attrText).underlineStyle != nil
    }
    private var isSelectionStrikethrough: Bool {
        selection.typingAttributes(in: attrText).strikethroughStyle != nil
    }

    private func applyBold() {
        let newBold = !isSelectionBold
        attrText.transformAttributes(in: &selection) { container in
            container.font = (container.font ?? .body).bold(newBold)
        }
    }

    private func applyItalic() {
        let newItalic = !isSelectionItalic
        attrText.transformAttributes(in: &selection) { container in
            container.font = (container.font ?? .body).italic(newItalic)
        }
    }

    private func applyUnderline() {
        let newStyle: Text.LineStyle? = isSelectionUnderline ? nil : Text.LineStyle(pattern: .solid)
        attrText.transformAttributes(in: &selection) { container in
            container.underlineStyle = newStyle
        }
    }

    private func applyStrikethrough() {
        let newStyle: Text.LineStyle? = isSelectionStrikethrough ? nil : Text.LineStyle(pattern: .solid)
        attrText.transformAttributes(in: &selection) { container in
            container.strikethroughStyle = newStyle
        }
    }

    // MARK: - RTF Export

    private func makeRTFData(from attrStr: AttributedString) -> Data {
        let nsAttr = NSMutableAttributedString()
        let baseFontSize: CGFloat = 16

        // Pre-compute known font variants — bold/italic detection via value equality
        // avoids Font.resolve(in:) which is only safe during SwiftUI rendering.
        let boldFont = Font.body.bold()
        let italicFont = Font.body.italic()
        let boldItalicA = Font.body.bold().italic()
        let boldItalicB = Font.body.italic().bold()

        for run in attrStr.runs {
            let substr = String(attrStr[run.range].characters)
            guard !substr.isEmpty else { continue }
            var nsAttrs: [NSAttributedString.Key: Any] = [:]

            let f = run.font
            let isBold = f == boldFont || f == boldItalicA || f == boldItalicB
            let isItalic = f == italicFont || f == boldItalicA || f == boldItalicB

            #if os(macOS)
            var nsFont = NSFont.systemFont(ofSize: baseFontSize)
            if isBold && isItalic {
                let desc = nsFont.fontDescriptor.withSymbolicTraits([.bold, .italic])
                if let resolved = NSFont(descriptor: desc, size: baseFontSize) { nsFont = resolved }
            } else if isBold {
                nsFont = NSFont.boldSystemFont(ofSize: baseFontSize)
            } else if isItalic {
                let desc = nsFont.fontDescriptor.withSymbolicTraits(.italic)
                if let resolved = NSFont(descriptor: desc, size: baseFontSize) { nsFont = resolved }
            }
            nsAttrs[.font] = nsFont
            #else
            var uiFont = UIFont.systemFont(ofSize: baseFontSize)
            if isBold || isItalic {
                var symTraits = uiFont.fontDescriptor.symbolicTraits
                if isBold { symTraits.insert(.traitBold) }
                if isItalic { symTraits.insert(.traitItalic) }
                if let desc = uiFont.fontDescriptor.withSymbolicTraits(symTraits) {
                    uiFont = UIFont(descriptor: desc, size: baseFontSize)
                }
            }
            nsAttrs[.font] = uiFont
            #endif

            if run.underlineStyle != nil {
                nsAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.strikethroughStyle != nil {
                nsAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            nsAttr.append(NSAttributedString(string: substr, attributes: nsAttrs))
        }

        guard nsAttr.length > 0 else { return Data() }
        return (try? nsAttr.data(
            from: NSRange(location: 0, length: nsAttr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )) ?? Data()
    }

    #if os(macOS)
    private func showRTFExporter() {
        let data = cachedRTFData
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf]
        panel.nameFieldStringValue = rtfFilename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    #endif

    // MARK: - Import

    private func importFile(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let ext = url.pathExtension.lowercased()
        let text: String

        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return }
            text = (0..<doc.pageCount)
                .compactMap { doc.page(at: $0)?.string }
                .joined(separator: "\n\n")
        case "rtf", "rtfd":
            guard let data = try? Data(contentsOf: url),
                  let attrStr = try? NSAttributedString(
                      data: data,
                      options: [.documentType: NSAttributedString.DocumentType.rtf],
                      documentAttributes: nil)
            else { return }
            text = attrStr.string
        default:
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            text = content
        }

        script.content = text
        script.richContent = nil
        attrText = AttributedString(text)
        if script.title.isEmpty || script.title == "Untitled Script" {
            script.title = url.deletingPathExtension().lastPathComponent
        }
        scheduleSave(attributedText: attrText)
    }

    // MARK: - Auto-Save

    private func scheduleSave(attributedText: AttributedString) {
        let snapshot = attributedText
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            isSaving = true
            script.richContent = try? JSONEncoder().encode(
                snapshot,
                configuration: AttributeScopes.SwiftUIAttributes.self)
            script.modifiedAt = Date()
            try? modelContext.save()
            isSaving = false
        }
    }
}
