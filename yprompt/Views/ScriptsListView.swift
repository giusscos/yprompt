//
//  ScriptsListView.swift
//  yprompt
//

import SwiftUI
import SwiftData

struct ScriptsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(StoreKitService.self) private var storeKit
    @Query(sort: \Script.modifiedAt, order: .reverse) private var scripts: [Script]
    @Query private var settingsArray: [AppSettings]

    // macOS uses a selection binding; iOS navigates via NavigationLink
    #if os(macOS)
    @Binding var selectedScript: Script?
    @State private var macSelectedIDs: Set<UUID> = []
    @State private var macSelectionOrder: [UUID] = []
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

    @State private var selectedTag: String? = nil
    @State private var scriptForTags: Script? = nil
    @State private var showTagQueueOrderSheet = false
    @State private var tagQueueOrdered: [Script] = []
    @State private var pendingPlay = false

    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectionOrder: [UUID] = []
    @State private var showingQueuePlayer = false
    @State private var queueToPlay: [Script] = []
    #endif

    private var allTags: [String] {
        let scriptTags = Set(scripts.flatMap { $0.tags })
        let definedTags = Set(settingsArray.first?.definedTags ?? [])
        return Array(scriptTags.union(definedTags)).sorted()
    }

    private var filtered: [Script] {
        var result = scripts
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        if let tag = selectedTag {
            result = result.filter { $0.tags.contains(tag) }
        }
        return result
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
            if let tag = selectedTag, !filtered.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        tagQueueOrdered = filtered
                        showTagQueueOrderSheet = true
                    } label: {
                        Label("Play \"\(tag)\"", systemImage: "play.fill")
                    }
                }
            }
            #if os(macOS)
            if macSelectedIDs.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Button { playQueueMac() } label: {
                        Label("Play Queue (\(macSelectedIDs.count))", systemImage: "play.fill")
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
            PaywallView().environment(storeKit)
        }
        .sheet(item: $scriptForTags) { script in
            TagPickerSheet(script: script)
        }
        .sheet(isPresented: $showTagQueueOrderSheet) {
            TagQueueOrderSheet(tag: selectedTag ?? "", scripts: $tagQueueOrdered) {
                #if os(macOS)
                let scripts = tagQueueOrdered
                DispatchQueue.main.async {
                    FloatingTeleprompterManager.shared.showQueue(scripts: scripts)
                }
                #else
                pendingPlay = true
                #endif
            }
        }
        #if os(iOS)
        .onChange(of: showTagQueueOrderSheet) { _, isShowing in
            if !isShowing && pendingPlay {
                pendingPlay = false
                playTagQueue(scripts: tagQueueOrdered)
            }
        }
        #endif
        #if os(iOS)
        .navigationDestination(isPresented: $showingQueuePlayer) {
            TeleprompterView(queue: queueToPlay)
                .environment(storeKit)
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

    // MARK: - Tag Filter Row

    private var tagFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tagPill(title: "All", isSelected: selectedTag == nil) { selectedTag = nil }
                ForEach(allTags, id: \.self) { tag in
                    tagPill(title: tag, isSelected: selectedTag == tag) {
                        selectedTag = (selectedTag == tag) ? nil : tag
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func tagPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
        .listSectionSpacing(.compact)
        .navigationDestination(for: Script.self) { script in
            EditorView(script: script)
                .environment(storeKit)
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
        List(selection: $macSelectedIDs) {
            listRows
        }
        .onChange(of: macSelectedIDs) { oldIDs, newIDs in
            if newIDs.count == 1, let id = newIDs.first,
               let script = scripts.first(where: { $0.id == id }) {
                selectedScript = script
                macSelectionOrder = [id]
            } else if newIDs.isEmpty {
                selectedScript = nil
                macSelectionOrder = []
            } else {
                selectedScript = nil
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
        if !allTags.isEmpty {
            Section {
                tagFilterRow
            }
        }
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
                    Button {
                        scriptForTags = script
                    } label: {
                        Label("Tags", systemImage: "tag")
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
        let isQueueing = macSelectedIDs.count > 1
        let queuePosition = isQueueing ? macSelectionOrder.firstIndex(of: script.id).map { $0 + 1 } : nil
        ScriptRowView(script: script, selectedScript: selectedScript, queuePosition: queuePosition, isSelectMode: isQueueing)
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

    private func playTagQueue(scripts: [Script]) {
        guard !scripts.isEmpty else { return }
        #if os(macOS)
        FloatingTeleprompterManager.shared.showQueue(scripts: scripts, storeKit: storeKit)
        #else
        queueToPlay = scripts
        editMode = .inactive
        selectedIDs = []
        selectionOrder = []
        showingQueuePlayer = true
        #endif
    }

    #if os(macOS)
    private func playQueueMac() {
        let ordered = macSelectionOrder.compactMap { id in filtered.first { $0.id == id } }
        guard !ordered.isEmpty else { return }
        FloatingTeleprompterManager.shared.showQueue(scripts: ordered, storeKit: storeKit)
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

// MARK: - Tag Queue Order Sheet

struct TagQueueOrderSheet: View {
    let tag: String
    @Binding var scripts: [Script]
    let onPlay: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Play \"\(tag)\"")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Play") {
                    onPlay()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()
            orderList
        }
        .frame(minWidth: 320, minHeight: 300)
        #else
        NavigationStack {
            orderList
                .navigationTitle("Play \"\(tag)\"")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Play") {
                            onPlay()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
        }
        #endif
    }

    private var orderList: some View {
        List {
            ForEach(Array(scripts.enumerated()), id: \.element.id) { index, script in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(script.title.isEmpty ? String(localized: "Untitled") : script.title)
                        .lineLimit(1)
                }
            }
            .onMove { source, destination in
                scripts.move(fromOffsets: source, toOffset: destination)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
    }
}

// MARK: - Tag Picker Sheet

struct TagPickerSheet: View {
    @Bindable var script: Script
    @Query private var allScripts: [Script]
    @Query private var settingsArray: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var newTagText = ""

    private var allTags: [String] {
        let scriptTags = Set(allScripts.flatMap { $0.tags })
        let definedTags = Set(settingsArray.first?.definedTags ?? [])
        return Array(scriptTags.union(definedTags)).sorted()
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Manage Tags")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()
            tagList
        }
        .frame(minWidth: 300, minHeight: 300)
        #else
        NavigationStack {
            tagList
                .navigationTitle("Manage Tags")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var tagList: some View {
        List {
            Section {
                HStack {
                    TextField("New tag", text: $newTagText)
                    Button("Add") { addTag() }
                        .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !allTags.isEmpty {
                Section("All Tags") {
                    ForEach(allTags, id: \.self) { tag in
                        Button { toggleTag(tag) } label: {
                            HStack {
                                Text(tag)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if script.tags.contains(tag) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggleTag(_ tag: String) {
        var tags = script.tags
        if tags.contains(tag) {
            tags.removeAll { $0 == tag }
        } else {
            tags.append(tag)
        }
        script.tags = tags
        try? modelContext.save()
    }

    private func addTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        toggleTag(trimmed)
        newTagText = ""
    }
}

// MARK: - Global Tag Manager

struct GlobalTagManagerView: View {
    @Query private var scripts: [Script]
    @Query private var settingsArray: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var tagToRename: String? = nil
    @State private var renameText = ""
    @State private var showRenameAlert = false
    @State private var newTagText = ""

    private var allTags: [String] {
        let scriptTags = Set(scripts.flatMap { $0.tags })
        let definedTags = Set(settingsArray.first?.definedTags ?? [])
        return Array(scriptTags.union(definedTags)).sorted()
    }

    private func scriptCount(for tag: String) -> Int {
        scripts.filter { $0.tags.contains(tag) }.count
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Manage Tags").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()
            tagList
        }
        .frame(minWidth: 300, minHeight: 300)
        .alert("Rename Tag", isPresented: $showRenameAlert) {
            TextField("Tag name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        #else
        tagList
            .navigationTitle("Manage Tags")
            .alert("Rename Tag", isPresented: $showRenameAlert) {
                TextField("Tag name", text: $renameText)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) {}
            }
        #endif
    }

    private var tagList: some View {
        List {
            Section {
                HStack {
                    TextField("New tag", text: $newTagText)
                    Button("Add") { createTag(newTagText) }
                        .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !allTags.isEmpty {
                Section("Tags") {
                    ForEach(allTags, id: \.self) { tag in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tag)
                                let count = scriptCount(for: tag)
                                Text("\(count) script\(count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contextMenu {
                            Button {
                                tagToRename = tag
                                renameText = tag
                                showRenameAlert = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) { deleteTag(tag) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { deleteTag(tag) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                tagToRename = tag
                                renameText = tag
                                showRenameAlert = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
    }

    private func createTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !allTags.contains(trimmed) else { return }
        guard let settings = settingsArray.first else { return }
        var tags = settings.definedTags
        tags.append(trimmed)
        settings.definedTags = tags
        try? modelContext.save()
        newTagText = ""
    }

    private func deleteTag(_ tag: String) {
        for script in scripts where script.tags.contains(tag) {
            script.tags = script.tags.filter { $0 != tag }
        }
        if let settings = settingsArray.first {
            settings.definedTags = settings.definedTags.filter { $0 != tag }
        }
        try? modelContext.save()
    }

    private func commitRename() {
        guard let old = tagToRename else { return }
        let new = renameText.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        for script in scripts where script.tags.contains(old) {
            var tags = script.tags
            if let idx = tags.firstIndex(of: old) {
                tags[idx] = new
            }
            script.tags = tags
        }
        if let settings = settingsArray.first {
            var tags = settings.definedTags
            if let idx = tags.firstIndex(of: old) {
                tags[idx] = new
            }
            settings.definedTags = tags
        }
        try? modelContext.save()
        tagToRename = nil
    }
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
                Text(script.title.isEmpty ? String(localized: "Untitled") : script.title)
                    .font(.headline)
                    .lineLimit(1)

                if !script.content.isEmpty {
                    Text(script.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !script.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(script.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }

                Text(script.modifiedAt.shortFormatted)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Group {
                if isSelectMode, let pos = queuePosition {
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
