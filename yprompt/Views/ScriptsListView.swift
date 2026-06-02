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
    @State private var macSelectionOrder: [UUID] = []
    @State private var macIsSelectMode: Bool = false
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
    @State private var selectionOrder: [UUID] = []
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
            ToolbarItem(placement: .cancellationAction) {
                if !macSelectedIDs.isEmpty {
                    Button {
                        playQueueMac()
                    } label: {
                        Label("Play Queue (\(macSelectedIDs.count))", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(macIsSelectMode ? "Done" : "Select") {
                        if macIsSelectMode {
                            macIsSelectMode = false
                            macSelectedIDs = []
                            macSelectionOrder = []
                        } else {
                            macIsSelectMode = true
                            macSelectedIDs = []
                            macSelectionOrder = []
                            selectedScript = nil
                        }
                    }
                }
            }
            #endif
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button(editMode == .active ? "Done" : "Select") {
                    if editMode == .active {
                        editMode = .inactive
                        selectedIDs = []
                        selectionOrder = []
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
        .navigationDestination(isPresented: $showingQueuePlayer) {
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
        .onChange(of: selectedIDs) { oldIDs, newIDs in
            let added = newIDs.subtracting(oldIDs)
            for id in added where !selectionOrder.contains(id) {
                selectionOrder.append(id)
            }
            selectionOrder.removeAll { !newIDs.contains($0) }
        }
        #else
        Group {
            if macIsSelectMode {
                List {
                    listRows
                }
            } else {
                List(selection: $macSelectedIDs) {
                    listRows
                }
            }
        }
        .onChange(of: macSelectedIDs) { oldIDs, newIDs in
            guard !macIsSelectMode else { return }
            if newIDs.count == 1, let id = newIDs.first,
               let script = scripts.first(where: { $0.id == id }) {
                selectedScript = script
                macSelectionOrder = [id]
            } else if newIDs.isEmpty {
                selectedScript = nil
                macSelectionOrder = []
            } else {
                let added = newIDs.subtracting(oldIDs)
                for id in added where !macSelectionOrder.contains(id) {
                    macSelectionOrder.append(id)
                }
                macSelectionOrder.removeAll { !newIDs.contains($0) }
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
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        scriptToDelete = script
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        renameTitle = script.title
                        scriptToRename = script
                        showRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                    Button {
                        duplicateScript(script)
                    } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                    .tint(.orange)
                }
        }
    }

    @ViewBuilder
    private func rowView(for script: Script) -> some View {
        #if os(macOS)
        let queuePosition = macSelectionOrder.firstIndex(of: script.id).map { $0 + 1 }
        let hideHeart = macIsSelectMode || macSelectedIDs.count > 1
        if macIsSelectMode {
            ScriptRowView(script: script, selectedScript: selectedScript, queuePosition: queuePosition, isSelectMode: hideHeart)
                .contentShape(Rectangle())
                .onTapGesture {
                    if macSelectedIDs.contains(script.id) {
                        macSelectedIDs.remove(script.id)
                        macSelectionOrder.removeAll { $0 == script.id }
                    } else {
                        macSelectedIDs.insert(script.id)
                        macSelectionOrder.append(script.id)
                    }
                }
        } else {
            ScriptRowView(script: script, selectedScript: selectedScript, queuePosition: queuePosition, isSelectMode: hideHeart)
        }
        #else
        let queuePosition = selectionOrder.firstIndex(of: script.id).map { $0 + 1 }
        NavigationLink(value: script) {
            ScriptRowView(script: script, queuePosition: queuePosition, isSelectMode: editMode == .active)
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
        let ordered = macSelectionOrder.compactMap { id in filtered.first { $0.id == id } }
        guard !ordered.isEmpty else { return }
        FloatingTeleprompterManager.shared.showQueue(scripts: ordered, storeKit: storeKit)
        macIsSelectMode = false
        macSelectedIDs = []
        macSelectionOrder = []
    }
    #endif

    #if os(iOS)
    private func playQueue() {
        let ordered = selectionOrder.compactMap { id in filtered.first { $0.id == id } }
        guard !ordered.isEmpty else { return }
        queueToPlay = ordered
        editMode = .inactive
        selectedIDs = []
        selectionOrder = []
        showingQueuePlayer = true
    }
    #endif
}

// MARK: - Script Row

struct ScriptRowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var script: Script

    var selectedScript: Script? = nil
    var queuePosition: Int? = nil
    var isSelectMode: Bool = false

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

            Group {
                if let pos = queuePosition {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 22, height: 22)
                        Text("\(pos)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: queuePosition)

            if !isSelectMode {
                Button {
                    script.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: script.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(script.isFavorite ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(script.isFavorite ? "Unfavorite" : "Favorite")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}
