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

// MARK: - AppSettings Model
@Model
final class AppSettings {
    var lastOpenedScriptID: UUID?
    var defaultFontName: String = "Menlo"
    var defaultFontSize: CGFloat = 28
    var defaultTextColorHex: String = "#000000"
    var defaultBackgroundColorHex: String = "#FFFFFF"
    var darkModeEnabled: Bool = false
    var cloudSyncEnabled: Bool = true
    var purchaseStateRaw: String = PurchaseState.free.rawValue
    var lastSyncDate: Date?

    var purchaseState: PurchaseState {
        get { PurchaseState(rawValue: purchaseStateRaw) ?? .free }
        set { purchaseStateRaw = newValue.rawValue }
    }

    init() {}
}
