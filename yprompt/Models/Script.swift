//
//  Script.swift
//  yprompt
//

import Foundation
import SwiftData

// MARK: - TextCustomization
struct TextCustomization: Codable, Sendable {
    var fontName: String = "Menlo"
    var fontSize: CGFloat = 28
    var textColorHex: String = "#000000"
    var backgroundColorHex: String = "#FFFFFF"
    var lineHeight: CGFloat = 1.4
    var textAlignmentIndex: Int = 0
    var transparency: Double = 1.0
    var scrollSpeed: Double = 1.0
    var isMirrored: Bool = false
    var isAutoScroll: Bool = true
}

// MARK: - CloudSyncState
enum CloudSyncState: String, Codable {
    case notSynced, pending, synced, failed
}

// MARK: - Script Model
@Model
final class Script: Hashable {
    static func == (lhs: Script, rhs: Script) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var id: UUID = UUID()
    var title: String = "Untitled Script"
    var content: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var customizationData: Data?
    var cloudSyncStateRaw: String = CloudSyncState.notSynced.rawValue
    var isFavorite: Bool = false

    var customization: TextCustomization {
        get {
            guard let data = customizationData,
                  let decoded = try? JSONDecoder().decode(TextCustomization.self, from: data)
            else { return TextCustomization() }
            return decoded
        }
        set {
            customizationData = try? JSONEncoder().encode(newValue)
        }
    }

    var cloudSyncState: CloudSyncState {
        get { CloudSyncState(rawValue: cloudSyncStateRaw) ?? .notSynced }
        set { cloudSyncStateRaw = newValue.rawValue }
    }

    init(title: String = "Untitled Script", content: String = "") {
        self.id = UUID()
        self.title = title
        self.content = content
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.cloudSyncStateRaw = CloudSyncState.notSynced.rawValue
        self.isFavorite = false
        self.customizationData = try? JSONEncoder().encode(TextCustomization())
    }
}
