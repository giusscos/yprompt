//
//  EditorView.swift
//  yprompt
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Markdown FileDocument

private struct MarkdownFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(
            data: configuration.file.regularFileContents ?? Data(),
            encoding: .utf8
        ) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: text.data(using: .utf8) ?? Data())
    }
}

// MARK: - EditorView

struct EditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.fontResolutionContext) private var fontContext
    @EnvironmentObject private var storeKit: StoreKitService
    @Bindable var script: Script

    @State private var attrText = AttributedString()
    @State private var selection = AttributedTextSelection()

    @State private var showingCustomization = false
    @State private var isSaving = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument: MarkdownFile? = nil
    @State private var showingRename = false
    @State private var renameText = ""
    #if os(iOS)
    @State private var showingTeleprompter = false
    #endif
    @State private var saveTask: Task<Void, Never>?

    private var exportFilename: String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let clean = script.title
            .components(separatedBy: unsafe)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return "\(clean.isEmpty ? "Untitled" : clean).md"
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
            .sheet(isPresented: $showingCustomization) {
                CustomizationView(script: script)
                    .environmentObject(storeKit)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingTeleprompter) {
                TeleprompterView(script: script)
                    .environmentObject(storeKit)
            }
            #endif
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.plainText],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    importMarkdown(from: url)
                }
            }
            .onChange(of: showingExporter) { _, isShowing in
                if isShowing { exportDocument = MarkdownFile(text: script.content) }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .plainText,
                defaultFilename: exportFilename
            ) { _ in
                exportDocument = nil
            }
            .alert("Rename Script", isPresented: $showingRename) {
                TextField("Title", text: $renameText)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { attrText = script.attributedContent }
            .onChange(of: script.id) { _, _ in attrText = script.attributedContent }
            .onChange(of: attrText) { _, newValue in
                script.content = String(newValue.characters)
                scheduleSave(attributedText: newValue)
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

            Divider()

            Button { applyBold() } label: { Label("Bold", systemImage: "bold") }
            Button { applyItalic() } label: { Label("Italic", systemImage: "italic") }
            Button { applyUnderline() } label: { Label("Underline", systemImage: "underline") }
            Button { applyStrikethrough() } label: { Label("Strikethrough", systemImage: "strikethrough") }
        }

        // Secondary group 1: Rename + Customize
        ToolbarItemGroup(placement: .secondaryAction) {
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
        ToolbarItemGroup(placement: .secondaryAction) {
            Button { showingImporter = true } label: {
                Label("Import Markdown", systemImage: "square.and.arrow.down")
            }
            Button { showingExporter = true } label: {
                Label("Export Markdown", systemImage: "square.and.arrow.up")
            }
            .disabled(script.content.isEmpty)
        }
        #else
        // iOS: Play button
        ToolbarItem(placement: .primaryAction) {
            Button { showingTeleprompter = true } label: {
                Label("Present", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(script.content.isEmpty)
        }

        // iOS: More menu — group 1: Rename + Customize
        ToolbarItem(placement: .secondaryAction) {
            Button {
                renameText = script.title
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button { showingCustomization = true } label: {
                Label("Customize", systemImage: "paintpalette")
            }
        }

        // iOS: More menu — group 2: Import + Export
        ToolbarItem(placement: .secondaryAction) {
            Button { showingImporter = true } label: {
                Label("Import Markdown", systemImage: "square.and.arrow.down")
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button { showingExporter = true } label: {
                Label("Export Markdown", systemImage: "square.and.arrow.up")
            }
            .disabled(script.content.isEmpty)
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

    // MARK: - Import

    private func importMarkdown(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
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
