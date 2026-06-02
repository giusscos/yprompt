//
//  Script.swift
//  yprompt
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - TextCustomization
struct TextCustomization: Sendable {
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

extension TextCustomization: Codable {
    enum CodingKeys: String, CodingKey {
        case fontSize, textColorHex, backgroundColorHex, lineHeight
        case textAlignmentIndex, transparency, scrollSpeed, isMirrored, isAutoScroll
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = (try? c.decode(CGFloat.self, forKey: .fontSize)) ?? 28
        textColorHex = (try? c.decode(String.self, forKey: .textColorHex)) ?? "#000000"
        backgroundColorHex = (try? c.decode(String.self, forKey: .backgroundColorHex)) ?? "#FFFFFF"
        lineHeight = (try? c.decode(CGFloat.self, forKey: .lineHeight)) ?? 1.4
        textAlignmentIndex = (try? c.decode(Int.self, forKey: .textAlignmentIndex)) ?? 0
        transparency = (try? c.decode(Double.self, forKey: .transparency)) ?? 1.0
        scrollSpeed = (try? c.decode(Double.self, forKey: .scrollSpeed)) ?? 1.0
        isMirrored = (try? c.decode(Bool.self, forKey: .isMirrored)) ?? false
        isAutoScroll = (try? c.decode(Bool.self, forKey: .isAutoScroll)) ?? true
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(textColorHex, forKey: .textColorHex)
        try c.encode(backgroundColorHex, forKey: .backgroundColorHex)
        try c.encode(lineHeight, forKey: .lineHeight)
        try c.encode(textAlignmentIndex, forKey: .textAlignmentIndex)
        try c.encode(transparency, forKey: .transparency)
        try c.encode(scrollSpeed, forKey: .scrollSpeed)
        try c.encode(isMirrored, forKey: .isMirrored)
        try c.encode(isAutoScroll, forKey: .isAutoScroll)
    }
}

// MARK: - CuePoint
struct CuePoint: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var position: Double  // 0.0 – 1.0 fraction of max scroll offset
    var label: String = ""
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
    var richContent: Data?
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var customizationData: Data?
    var cloudSyncStateRaw: String = CloudSyncState.notSynced.rawValue
    var isFavorite: Bool = false
    var cuePointsData: Data?

    var attributedContent: AttributedString {
        get {
            if let data = richContent,
               let decoded = try? JSONDecoder().decode(
                   AttributedString.self, from: data,
                   configuration: AttributeScopes.SwiftUIAttributes.self) {
                return decoded
            }
            return AttributedString(content)
        }
        set {
            richContent = try? JSONEncoder().encode(
                newValue,
                configuration: AttributeScopes.SwiftUIAttributes.self)
            content = String(newValue.characters)
        }
    }

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

    var cuePoints: [CuePoint] {
        get {
            guard let data = cuePointsData,
                  let decoded = try? JSONDecoder().decode([CuePoint].self, from: data)
            else { return [] }
            return decoded
        }
        set { cuePointsData = try? JSONEncoder().encode(newValue) }
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
