//
//  AppSettings.swift
//  yprompt
//

import Foundation
import SwiftData

// MARK: - PurchaseState
enum PurchaseState: String, Codable {
    case free, lifetime, subscribed
}

// MARK: - DisplayMode
enum DisplayMode: String, Codable, Hashable {
    case floatingWindow, notch
}

// MARK: - AppSettings Model
@Model
final class AppSettings {
    var lastOpenedScriptID: UUID?
    var defaultFontSize: CGFloat = 28
    var defaultTextColorHex: String = "#000000"
    var defaultBackgroundColorHex: String = "#FFFFFF"
    var darkModeEnabled: Bool = false
    var cloudSyncEnabled: Bool = true
    var purchaseStateRaw: String = PurchaseState.free.rawValue
    var lastSyncDate: Date?

    // MARK: Teleprompter Preferences
    var displayModeRaw: String = "floatingWindow"
    var floatingWindowWidth: CGFloat = 780
    var floatingWindowHeight: CGFloat = 116
    var floatingFontSize: CGFloat = 19
    var notchFontSize: CGFloat = 11
    var defaultScrollSpeed: Double = 1.0
    var definedTagsData: Data?

    var definedTags: [String] {
        get {
            guard let data = definedTagsData,
                  let decoded = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return decoded
        }
        set { definedTagsData = try? JSONEncoder().encode(newValue) }
    }

    var purchaseState: PurchaseState {
        get { PurchaseState(rawValue: purchaseStateRaw) ?? .free }
        set { purchaseStateRaw = newValue.rawValue }
    }

    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: displayModeRaw) ?? .floatingWindow }
        set { displayModeRaw = newValue.rawValue }
    }

    init() {}
}
