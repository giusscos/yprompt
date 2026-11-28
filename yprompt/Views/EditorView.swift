//
//  EditorView.swift
//  yprompt
//

import SwiftUI
import TipKit
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
    private let presentTip = PresentTip()
    @Environment(\.modelContext) private var modelContext
    @Environment(StoreKitService.self) private var storeKit
    @Bindable var script: Script

    @State private var attrText = AttributedString()
    @State private var formatRequest: TextFormat?
    #if os(iOS)
    /// Whether the page is being typed in, and its Undo and Done.
    @State private var editor = ScriptEditorController()
    #endif

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
    #if os(iOS) || os(visionOS)
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
            // The title is the page's heading, so the bar only names it for the back menu.
            .navigationTitle(script.title)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(HiddenNavigationTitle())
            #elseif os(visionOS)
            .navigationTitle(script.title)
            .navigationBarTitleDisplayMode(.inline)
            #elseif os(macOS)
            // Set macOS window title directly — avoids the always-black auto-title in the toolbar
            .onAppear { NSApp.mainWindow?.title = script.title }
            .onChange(of: script.title) { _, new in NSApp.mainWindow?.title = new }
            #endif
            .toolbar { toolbarItems }
            #if os(iOS) || os(visionOS)
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
            #if os(iOS) || os(visionOS)
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

    @ViewBuilder
    private var editorArea: some View {
        #if os(iOS)
        ScriptTextEditor(
            text: $attrText,
            title: Binding(get: { script.title }, set: { newTitle in
                script.title = newTitle
                scheduleSave(attributedText: attrText)
            }),
            controller: editor,
            focusOnAppear: script.content.isEmpty
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // While typing, the count sits beside the format buttons instead.
            if !editor.isEditing {
                wordCountBar
            }
        }
        // The text view makes room for the keyboard itself, so the count stays at the bottom
        // of the page and never lands where the keyboard used to be.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #elseif os(macOS)
        VStack(spacing: 0) {
            // Keeps the page from reaching under the toolbar, whose glass would sample it and
            // draw the title and buttons dark.
            Color.clear.frame(height: 1)
            MacScriptTextEditor(
                text: $attrText,
                title: Binding(get: { script.title }, set: { newTitle in
                    script.title = newTitle
                    scheduleSave(attributedText: attrText)
                }),
                formatRequest: $formatRequest,
                focusOnAppear: script.content.isEmpty
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            wordCountBar
        }
        #else
        MarkdownEditorView(
            text: $attrText,
            formatRequest: $formatRequest,
            focusOnAppear: script.content.isEmpty
        )
        .overlay(alignment: .topLeading) {
            if attrText.characters.isEmpty {
                Text("Type or paste your script here…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    // Where the first typed character lands: the Mac text view has a smaller inset.
                    #if os(macOS)
                    .padding(.leading, 4)
                    .padding(.top, 2)
                    #else
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    #endif
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            wordCountBar
        }
        #endif
    }

    private var wordCountBar: some View {
        HStack(spacing: 12) {
            if wordCount == 0 {
                // The quickest ways to get a script in.
                PasteButton(payloadType: String.self) { strings in
                    attrText = AttributedString(strings.joined(separator: "\n"))
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                Button { showingImporter = true } label: {
                    Label("Import File", systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            } else {
                (wordCount == 1
                    ? Text("1 word  ·  ~\(readTimeMinutes) min")
                    : Text("\(wordCount) words  ·  ~\(readTimeMinutes) min"))
                    .foregroundStyle(.secondary)
                    .font(.caption2.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        #if os(iOS)
        // The page fades out under it rather than meeting a bar.
        .background {
            LinearGradient(stops: [.init(color: Color(.systemBackground).opacity(0), location: 0),
                                   .init(color: Color(.systemBackground), location: 0.6)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -12)
                .ignoresSafeArea(edges: .bottom)
        }
        #else
        .background(.bar)
        #endif
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
            .popoverTip(presentTip)
            .disabled(script.content.isEmpty)

            Button {
                let manager = FloatingTeleprompterManager.shared
                if manager.recordMode == .off { manager.recordMode = .camera }
                manager.show(script: script, storeKit: storeKit)
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .help("Read this script with the camera on, ready to record")
            .disabled(script.content.isEmpty)

            Button { formatRequest = .bold } label: { Label("Bold", systemImage: "bold") }
                .help("Bold (⌘B)")
            Button { formatRequest = .italic } label: { Label("Italic", systemImage: "italic") }
                .help("Italic (⌘I)")
            Button { formatRequest = .underline } label: { Label("Underline", systemImage: "underline") }
                .help("Underline (⌘U)")
            Button { formatRequest = .strikethrough } label: { Label("Strikethrough", systemImage: "strikethrough") }
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
        #elseif os(iOS)
        // While typing: Undo, More and Done, as in Notes. Otherwise More and Present.
        if editor.isEditing {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editor.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!editor.canUndo)
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button { editor.endEditing() } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
            ToolbarItem(placement: .topBarTrailing) { presentButton }
        }
        #else
        ToolbarItem(placement: .topBarTrailing) { presentButton }
        ToolbarItem(placement: .topBarTrailing) { moreMenu }
        #endif
    }

    #if !os(macOS)
    /// Play: hides the tab bar with a slide down before the reading screen comes in.
    private var presentButton: some View {
        Button {
            #if os(iOS)
            TabBarAnimator.setHidden(true, animated: true)
            #endif
            showingTeleprompter = true
        } label: {
            Label("Present", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .popoverTip(presentTip)
        .disabled(script.content.isEmpty)
    }

    /// Customize, Import and Export (and Rename on Vision Pro; elsewhere the title is typed in place).
    private var moreMenu: some View {
        Menu {
            #if os(visionOS)
            Button {
                renameText = script.title
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            #endif

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

    // MARK: - Rename

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        script.title = trimmed
        scheduleSave(attributedText: attrText)
    }

    // MARK: - RTF Export

    private func makeRTFData(from attrStr: AttributedString) -> Data {
        let nsAttr = NSMutableAttributedString()
        let baseFontSize: CGFloat = 16

        for run in attrStr.runs {
            let substr = String(attrStr[run.range].characters)
            guard !substr.isEmpty else { continue }
            var nsAttrs: [NSAttributedString.Key: Any] = [:]

            let (isBold, isItalic) = run.font?.ypEditorTraits ?? (false, false)

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

#if os(iOS)
/// Keeps the script's name out of the navigation bar, where the page's own heading already is.
private struct HiddenNavigationTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.toolbar(removing: .title)
        } else {
            content.toolbar {
                ToolbarItem(placement: .principal) { Text(verbatim: "") }
            }
        }
    }
}
#endif
