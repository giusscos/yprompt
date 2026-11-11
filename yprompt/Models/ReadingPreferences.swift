//
//  ReadingPreferences.swift
//  yprompt
//

import Foundation

/// What the reader last chose. It follows them from script to script, so nothing has to be set
/// up again. These stay on the device: a phone and a Mac need different sizes and margins.
enum ReadingPreferences {
    static let modeKey = "reading.mode"
    static let backgroundKey = "reading.background"
    static let speedKey = "reading.speed"
    static let fontSizeKey = "reading.fontSize"
    static let marginsKey = "reading.margins"
    static let timedSecondsKey = "reading.timedSeconds"
    static let cameraPositionKey = "reading.cameraPosition"
    static let newScriptStyleKey = "reading.newScriptStyle"
    static let takeTrimKey = "takes.trim"
    nonisolated static let takeCaptionStyleKey = "takes.captionStyle"
    nonisolated static let takeCaptionPositionKey = "takes.captionPosition"

    static let cameraBackground = "camera"
    static let audioBackground = "audio"
    static let colorBackground = "color"
    static let backCamera = "back"

    private static var defaults: UserDefaults { .standard }

    /// Zero until the reader picks one; each script's own value applies until then.
    static var speed: Double {
        get { defaults.double(forKey: speedKey) }
        set { defaults.set(newValue, forKey: speedKey) }
    }

    /// Zero until the reader picks one; each script's own value applies until then.
    static var fontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: fontSizeKey)) }
        set { defaults.set(Double(newValue), forKey: fontSizeKey) }
    }

    /// The Customize sheet's last choices, which new scripts start from.
    static var newScriptStyle: TextCustomization? {
        get {
            defaults.data(forKey: newScriptStyleKey)
                .flatMap { try? JSONDecoder().decode(TextCustomization.self, from: $0) }
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: newScriptStyleKey) }
    }

    static func reset() {
        for key in [modeKey, backgroundKey, speedKey, fontSizeKey, marginsKey,
                    timedSecondsKey, cameraPositionKey, newScriptStyleKey,
                    takeTrimKey, takeCaptionStyleKey, takeCaptionPositionKey,
                    ReadingFont.key, LetterSpacing.key] {
            defaults.removeObject(forKey: key)
        }
    }
}
