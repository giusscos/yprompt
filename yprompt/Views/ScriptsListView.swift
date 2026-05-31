//
//  ScriptsListView.swift
//  yprompt
//

import SwiftUI
import SwiftData

struct ScriptsListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var storeKit: StoreKitService
    @Query(sort: \Script.modifiedAt, order: .reverse) private var scripts: [Script]
    @Query private var settingsArray: [AppSettings]

    // macOS uses a selection binding; iOS navigates via NavigationLink
    #if os(macOS)
    @Binding var selectedScript: Script?
    @State private var macSelectedIDs: Set<UUID> = []
    init(selectedScript: Binding<Script?>) {
        self._selectedScript = selectedScript
    }
    #else
    init() {}
    #endif

    @State private var searchText = ""
    @State private var showingPaywall = false
    @State private var scriptToDelete: Script?
    @State private var showDeleteConfirm = false

    @State private var showingNewScriptAlert = false
    @State private var newScriptTitle = ""

    @State private var scriptToRename: Script?
    @State private var renameTitle = ""
    @State private var showRenameAlert = false

    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingQueuePlayer = false
    @State private var queueToPlay: [Script] = []
    #endif

    private var filtered: [Script] {
        guard !searchText.isEmpty else { return scripts }
        return scripts.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if scripts.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
        .navigationTitle("Scripts")
        #if os(iOS)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        #else
        .searchable(text: $searchText, prompt: "Search")
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: requestCreateScript) {
                    Label("New Script", systemImage: "plus")
                }
            }
            #if os(macOS)
            if macSelectedIDs.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Button { playQueueMac() } label: {
                        Label("Play Queue (\(macSelectedIDs.count))", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            #endif
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button(editMode == .active ? "Done" : "Select") {
                    if editMode == .active {
                        editMode = .inactive
                        selectedIDs = []
                    } else {
                        editMode = .active
                    }
                }
            }
            if editMode == .active && !selectedIDs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { playQueue() } label: {
                        Label("Play Queue (\(selectedIDs.count))", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            #endif
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView().environmentObject(storeKit)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingQueuePlayer) {
            TeleprompterView(queue: queueToPlay)
                .environmentObject(storeKit)
        }
        #endif
        .confirmationDialog(
            "Delete Script?",
            isPresented: $showDeleteConfirm,
            presenting: scriptToDelete
        ) { script in
            Button("Delete \"\(script.title)\"", role: .destructive) {
                delete(script)
            }
        } message: { script in
            Text("This will permanently delete \"\(script.title)\".")
        }
        .alert("New Script", isPresented: $showingNewScriptAlert) {
            TextField("Title", text: $newScriptTitle)
            Button("Create") { createScript(title: newScriptTitle) }
            Button("Cancel", role: .cancel) { newScriptTitle = "" }
        } message: {
            Text("Enter a title for your script.")
        }
        .alert("Rename Script", isPresented: $showRenameAlert) {
            TextField("Title", text: $renameTitle)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No Scripts")
                .font(.title2.bold())
            Text("Tap + to create your first script.")
                .foregroundStyle(.secondary)
            Button("Create Script", action: requestCreateScript)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var listContent: some View {
        #if os(iOS)
        List(selection: $selectedIDs) {
            listRows
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: Script.self) { script in
            EditorView(script: script)
                .environmentObject(storeKit)
        }
        .environment(\.editMode, $editMode)
        #else
        List(selection: $macSelectedIDs) {
            listRows
        }
        .onChange(of: macSelectedIDs) { _, ids in
            if ids.count == 1, let id = ids.first,
               let script = scripts.first(where: { $0.id == id }) {
                selectedScript = script
            } else if ids.isEmpty {
                selectedScript = nil
            }
        }
        #endif
    }

    @ViewBuilder
    private var listRows: some View {
        ForEach(filtered) { script in
            rowView(for: script)
                .contextMenu {
                    Button {
                        renameTitle = script.title
                        scriptToRename = script
                        showRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        duplicateScript(script)
                    } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) {
                        scriptToDelete = script
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder
    private func rowView(for script: Script) -> some View {
        #if os(macOS)
        ScriptRowView(script: script, selectedScript: selectedScript)
        #else
        NavigationLink(value: script) {
            ScriptRowView(script: script)
        }
        #endif
    }

    // MARK: - Actions

    private func requestCreateScript() {
        guard storeKit.isPremium || scripts.count < AppConstants.freeScriptLimit else {
            showingPaywall = true
            return
        }
        newScriptTitle = ""
        showingNewScriptAlert = true
    }

    private func createScript(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let script = Script(title: trimmed.isEmpty ? "Untitled Script" : trimmed)
        if let settings = settingsArray.first {
            var customization = TextCustomization()
            customization.fontSize = settings.defaultFontSize
            customization.scrollSpeed = settings.defaultScrollSpeed
            script.customization = customization
        }
        modelContext.insert(script)
        try? modelContext.save()
        newScriptTitle = ""
        #if os(macOS)
        selectedScript = script
        #endif
    }

    private func commitRename() {
        guard let script = scriptToRename else { return }
        let trimmed = renameTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        script.title = trimmed
        try? modelContext.save()
        scriptToRename = nil
    }

    private func duplicateScript(_ script: Script) {
        let copy = Script(title: script.title + " Copy", content: script.content)
        copy.customizationData = script.customizationData
        modelContext.insert(copy)
        try? modelContext.save()
    }

    private func delete(_ script: Script) {
        #if os(macOS)
        if selectedScript?.id == script.id { selectedScript = nil }
        macSelectedIDs.remove(script.id)
        #endif
        modelContext.delete(script)
        try? modelContext.save()
    }

    #if os(macOS)
    private func playQueueMac() {
        let ordered = filtered.filter { macSelectedIDs.contains($0.id) }
        guard ordered.count > 1 else { return }
        FloatingTeleprompterManager.shared.showQueue(scripts: ordered, storeKit: storeKit)
        macSelectedIDs = []
    }
    #endif

    #if os(iOS)
    private func playQueue() {
        let ordered = filtered.filter { selectedIDs.contains($0.id) }
        guard !ordered.isEmpty else { return }
        queueToPlay = ordered
        editMode = .inactive
        selectedIDs = []
        showingQueuePlayer = true
    }
    #endif
}

// MARK: - Script Row

struct ScriptRowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var script: Script

    var selectedScript: Script? = nil

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(script.title.isEmpty ? "Untitled" : script.title)
                    .font(.headline)
                    .lineLimit(1)

                if !script.content.isEmpty {
                    Text(script.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(script.modifiedAt.shortFormatted)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                script.isFavorite.toggle()
                try? modelContext.save()
            } label: {
                Image(systemName: script.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(script.isFavorite ? Color.pink : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(script.isFavorite ? "Unfavorite" : "Favorite")
        }
        .padding(8)
        .background(selectedScript?.id == script.id ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(.rect(cornerRadius: 16))
    }
}
