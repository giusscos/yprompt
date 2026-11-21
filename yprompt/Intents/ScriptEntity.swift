//
//  ScriptEntity.swift
//  yprompt
//

import AppIntents
import CoreSpotlight
import Foundation

/// A script as Shortcuts, Siri, Spotlight and Apple Intelligence see it.
struct ScriptEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Script"),
        numericFormat: LocalizedStringResource("\(placeholder: .int) scripts")
    )
    static let defaultQuery = ScriptQuery()

    var id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Text")
    var text: String

    @Property(title: "Words")
    var wordCount: Int

    @Property(title: "Reading Time (minutes)")
    var readingMinutes: Int

    @Property(title: "Modified")
    var modifiedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(wordCount) words · ~\(readingMinutes) min",
            image: .init(systemName: "text.alignleft")
        )
    }

    @MainActor
    init(_ script: Script) {
        id = script.id
        let words = script.content.split(whereSeparator: \.isWhitespace).count
        title = script.title
        text = script.content
        wordCount = words
        // The same reading pace the editor shows.
        readingMinutes = max(1, Int((Double(words) / 130).rounded(.up)))
        modifiedAt = script.modifiedAt
    }
}

struct ScriptQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ScriptEntity] {
        identifiers.compactMap(AppDataStore.script(id:)).map(ScriptEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ScriptEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces)
        return AppDataStore.allScripts()
            .filter { needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle)
                || $0.content.localizedCaseInsensitiveContains(needle) }
            .map(ScriptEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ScriptEntity] {
        AppDataStore.allScripts().prefix(20).map(ScriptEntity.init)
    }
}

// MARK: - Spotlight and Apple Intelligence

@available(iOS 18.0, macOS 15.0, *)
extension ScriptEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = String(text.prefix(300))
        attributes.textContent = text
        attributes.contentModificationDate = modifiedAt
        return attributes
    }
}

/// Keeps Spotlight's copy of the scripts current, so they can be found by what they say and
/// Siri and Apple Intelligence can refer to them.
enum ScriptIndex {
    @MainActor
    static func update(_ scripts: [Script]) {
        guard #available(iOS 18.0, macOS 15.0, *), !scripts.isEmpty, !isDemo else { return }
        let entities = scripts.map(ScriptEntity.init)
        Task { try? await CSSearchableIndex.default().indexAppEntities(entities) }
    }

    @MainActor
    static func remove(_ ids: [UUID]) {
        guard #available(iOS 18.0, macOS 15.0, *), !ids.isEmpty else { return }
        Task { try? await CSSearchableIndex.default().deleteAppEntities(identifiedBy: ids, ofType: ScriptEntity.self) }
    }

    /// Everything, once per launch: picks up scripts that synced in from other devices, and
    /// drops any left over from scripts deleted elsewhere.
    @MainActor
    static func rebuild() {
        guard #available(iOS 18.0, macOS 15.0, *), !isDemo else { return }
        let entities = AppDataStore.allScripts().map(ScriptEntity.init)
        Task {
            try? await CSSearchableIndex.default().deleteAppEntities(ofType: ScriptEntity.self)
            if !entities.isEmpty { try? await CSSearchableIndex.default().indexAppEntities(entities) }
        }
    }

    /// The screenshot library's sample scripts stay out of Spotlight.
    private static var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ypDemoStore")
        #else
        false
        #endif
    }
}
