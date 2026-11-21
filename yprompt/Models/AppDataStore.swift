//
//  AppDataStore.swift
//  yprompt
//

import Foundation
import SwiftData

/// The one place scripts are stored, shared by the app's windows and by its App Intents,
/// which can run (from Shortcuts, Siri or Spotlight) without a window open.
@MainActor
enum AppDataStore {
    static let container: ModelContainer = {
        let schema = Schema([Script.self, AppSettings.self])
        var config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        #if DEBUG
        // For App Store screenshots: an empty library in memory, apart from iCloud, which the
        // sample scripts then fill. The real library isn't touched.
        if ProcessInfo.processInfo.arguments.contains("-ypDemoStore") {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        #endif
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    static var context: ModelContext { container.mainContext }

    static func script(id: UUID) -> Script? {
        var descriptor = FetchDescriptor<Script>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func allScripts() -> [Script] {
        let descriptor = FetchDescriptor<Script>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    enum StoreError: LocalizedError {
        case freeLimitReached

        var errorDescription: String? {
            switch self {
            case .freeLimitReached:
                String(localized: "The free version holds \(AppConstants.freeScriptLimit) scripts. Upgrade to yPrompt Pro for unlimited scripts.")
            }
        }
    }

    /// Adds a script the way the New Script button does: with the reader's usual style, and
    /// within the free version's limit.
    static func makeScript(title: String, text: String) async throws -> Script {
        let store = StoreKitService.shared
        await store.refreshEntitlements()
        let count = allScripts().filter { $0.id != AppConstants.welcomeScriptID }.count
        guard store.isPremium || count < AppConstants.freeScriptLimit else { throw StoreError.freeLimitReached }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = Script(title: trimmed.isEmpty ? String(localized: "Untitled Script") : trimmed, content: text)
        var customization = ReadingPreferences.newScriptStyle ?? TextCustomization()
        if ReadingPreferences.newScriptStyle == nil,
           let settings = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            customization.fontSize = settings.defaultFontSize
            customization.scrollSpeed = settings.defaultScrollSpeed
        }
        script.customization = customization
        context.insert(script)
        try context.save()
        ScriptIndex.update([script])
        return script
    }

    /// Saves a change to a script's text, keeping its formatting where it can.
    static func setText(of script: Script, to text: String) throws {
        script.attributedContent = AttributedString(text)
        script.modifiedAt = Date()
        try context.save()
        ScriptIndex.update([script])
    }

    static func append(_ text: String, to script: Script) throws {
        let separator = script.content.isEmpty ? "" : "\n\n"
        script.attributedContent = script.attributedContent + AttributedString(separator + text)
        script.modifiedAt = Date()
        try context.save()
        ScriptIndex.update([script])
    }
}
