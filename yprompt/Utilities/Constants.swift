//
//  Constants.swift
//  yprompt
//

import SwiftUI

enum AppConstants {
    // MARK: - Demo StoreKit Product IDs
    // static let lifetimeProductID = "com.yprompt.lifetime"
    // static let weeklySubscriptionID = "com.yprompt.weekly"
    // static let yearlySubscriptionID = "com.yprompt.yearly"
    
    // MARK: - StoreKit Product IDs
    static let lifetimeProductID = "yp_8999_lifetime"
    static let weeklySubscriptionID = "yp_599_1w"
    static let yearlySubscriptionID = "yp_4999_1y"
    /// Legacy — removed from sale; kept so existing monthly subscribers retain access.
    static let monthlySubscriptionID = "yp_499_1m"

    // MARK: - Legal URLs
    static let privacyPolicyURL = URL(string: "https://yprompt.app/privacy")!
    static let termsOfUseURL = URL(string: "https://yprompt.app/terms")!

    // MARK: - Free Tier
    static let freeScriptLimit = 3

    // MARK: - Scroll
    static let minScrollSpeed: Double = 0.25
    static let maxScrollSpeed: Double = 5.0
    static let defaultScrollSpeed: Double = 1.0
    static let basePixelsPerSecond: CGFloat = 60

    // MARK: - Font Size
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 120
    static let defaultFontSize: CGFloat = 28

    // MARK: - Line Height
    static let minLineHeight: CGFloat = 1.0
    static let maxLineHeight: CGFloat = 4.0
    static let defaultLineHeight: CGFloat = 1.4

    // MARK: - Default Colors
    static let defaultTextColorHex = "#000000"
    static let defaultBackgroundColorHex = "#FFFFFF"

    // MARK: - Text Color Presets
    static let textColorPresets: [(name: String, hex: String)] = [
        ("Black", "#000000"),
        ("White", "#FFFFFF"),
        ("Red", "#FF3B30"),
        ("Blue", "#007AFF"),
        ("Green", "#34C759"),
        ("Yellow", "#FFCC00"),
        ("Purple", "#AF52DE"),
        ("Gray", "#8E8E93"),
        ("Orange", "#FF9500"),
        ("Cyan", "#32ADE6"),
        ("Pink", "#FF2D55"),
        ("Brown", "#A2845E")
    ]

    // MARK: - Background Color Presets
    static let backgroundColorPresets: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"),
        ("Black", "#000000"),
        ("Dark Gray", "#1C1C1E"),
        ("Light Gray", "#F2F2F7"),
        ("Cream", "#FFFDD0"),
        ("Light Blue", "#E3F2FD"),
        ("Light Yellow", "#FFFDE7"),
        ("Light Green", "#E8F5E9"),
        ("Navy", "#001F3F"),
        ("Charcoal", "#2C3E50"),
        ("Beige", "#F5F5DC"),
        ("Mint", "#98FF98")
    ]
}
