//
//  ScriptViewModel.swift
//  yprompt
//

import Foundation
import SwiftData

@Observable @MainActor
class ScriptViewModel {
    var isSaving = false
    var errorMessage: String?

    private let modelContext: ModelContext
    private var saveTask: Task<Void, Never>?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Save

    func scheduleSave(for script: Script) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            save(script)
        }
    }

    func save(_ script: Script) {
        isSaving = true
        script.modifiedAt = Date()
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - Customization

    func applyCustomization(_ customization: TextCustomization, to script: Script) {
        script.customization = customization
        save(script)
    }

    func toggleFavorite(_ script: Script) {
        script.isFavorite.toggle()
        save(script)
    }

    // MARK: - Stats

    func wordCount(for script: Script) -> Int {
        script.content.split { $0.isWhitespace }.count
    }
}
