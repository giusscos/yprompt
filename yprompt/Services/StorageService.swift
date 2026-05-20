//
//  StorageService.swift
//  yprompt
//

import Foundation
import Combine
import SwiftData

@MainActor
class StorageService: ObservableObject {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Script CRUD

    func fetchAllScripts() throws -> [Script] {
        let descriptor = FetchDescriptor<Script>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func searchScripts(query: String) throws -> [Script] {
        let descriptor = FetchDescriptor<Script>(
            predicate: #Predicate { $0.title.localizedStandardContains(query) },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    @discardableResult
    func createScript(title: String = "Untitled Script") -> Script {
        let script = Script(title: title)
        modelContext.insert(script)
        try? modelContext.save()
        return script
    }

    func deleteScript(_ script: Script) {
        modelContext.delete(script)
        try? modelContext.save()
    }

    func saveScript(_ script: Script) {
        script.modifiedAt = Date()
        try? modelContext.save()
    }

    func toggleFavorite(_ script: Script) {
        script.isFavorite.toggle()
        try? modelContext.save()
    }

    // MARK: - AppSettings

    func fetchOrCreateSettings() -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let settings = AppSettings()
        modelContext.insert(settings)
        try? modelContext.save()
        return settings
    }

    func saveSettings() {
        try? modelContext.save()
    }
}
