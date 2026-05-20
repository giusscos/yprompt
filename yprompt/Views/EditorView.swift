//
//  EditorView.swift
//  yprompt
//

import SwiftUI
import SwiftData

struct EditorView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var storeKit: StoreKitService
    @Bindable var script: Script

    @State private var showingCustomization = false
    @State private var isSaving = false
    #if os(iOS)
    @State private var showingTeleprompter = false
    #endif
    @State private var saveTask: Task<Void, Never>?

    private var customization: TextCustomization { script.customization }

    var body: some View {
        VStack(spacing: 0) {
            titleField
            Divider()
            editorArea
        }
        .navigationTitle(script.title.isEmpty ? "Untitled" : script.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
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
    }

    // MARK: - Subviews

    private var titleField: some View {
        TextField("Script Title", text: Binding(
            get: { script.title },
            set: { script.title = $0; scheduleSave() }
        ))
        .textFieldStyle(.plain)
        .font(.title.bold())
        .padding()
        #if os(iOS)
        .textInputAutocapitalization(.sentences)
        #endif
    }

    private var editorArea: some View {
        ZStack(alignment: .bottomTrailing) {
            TextEditor(text: Binding(
                get: { script.content },
                set: { script.content = $0; scheduleSave() }
            ))
            .font(.custom(customization.fontName, size: customization.fontSize))
            .foregroundStyle(Color(hex: customization.textColorHex))
            .scrollContentBackground(.hidden)
            .padding(.horizontal)
            .background(Color(hex: customization.backgroundColorHex))

            charCountBadge
        }
    }

    private var charCountBadge: some View {
        Text("\(script.content.count) chars · \(wordCount) words")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(12)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(12)
    }

    private var wordCount: Int {
        script.content.split { $0.isWhitespace }.count
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                #if os(macOS)
                FloatingTeleprompterManager.shared.show(script: script, storeKit: storeKit)
                #else
                showingTeleprompter = true
                #endif
            } label: {
                Label("Present", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(script.content.isEmpty)
        }
        ToolbarItem(placement: .secondaryAction) {
            Button {
                showingCustomization = true
            } label: {
                Label("Customize", systemImage: "paintpalette")
            }
        }
    }

    // MARK: - Auto-Save

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            isSaving = true
            script.modifiedAt = Date()
            try? modelContext.save()
            isSaving = false
        }
    }
}
