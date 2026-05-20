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

    // macOS uses a selection binding; iOS navigates via NavigationLink
    #if os(macOS)
    @Binding var selectedScript: Script?
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
        .searchable(text: $searchText, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createScript) {
                    Label("New Script", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView().environmentObject(storeKit)
        }
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
            Button("Create Script", action: createScript)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var listContent: some View {
        List {
            ForEach(filtered) { script in
                rowView(for: script)
                    .contextMenu {
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
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationDestination(for: Script.self) { script in
            EditorView(script: script)
                .environmentObject(storeKit)
        }
        #endif
    }

    @ViewBuilder
    private func rowView(for script: Script) -> some View {
        #if os(macOS)
        ScriptRowView(script: script, selectedScript: selectedScript)
            .onTapGesture { selectedScript = script }
        #else
        NavigationLink(value: script) {
            ScriptRowView(script: script)
        }
        #endif
    }

    // MARK: - Actions

    private func createScript() {
        guard storeKit.isPremium || scripts.count < AppConstants.freeScriptLimit else {
            showingPaywall = true
            return
        }
        let script = Script()
        modelContext.insert(script)
        try? modelContext.save()
        #if os(macOS)
        selectedScript = script
        #endif
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
        #endif
        modelContext.delete(script)
        try? modelContext.save()
    }
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
