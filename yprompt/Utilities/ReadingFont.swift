//
//  ReadingFont.swift
//  yprompt
//

import SwiftUI
import CoreText
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The typeface scripts are read in. It belongs to the reader, not the script, so it stays on the
/// device like text size does, and it's free for everyone. The bundled fonts only draw Latin
/// letters (and, for OpenDyslexic, Greek and Cyrillic); other alphabets such as Chinese or Arabic
/// stay in the system font.
enum ReadingFont: String, CaseIterable, Identifiable, Sendable {
    case system
    /// Atkinson Hyperlegible Next, from the Braille Institute: letters that are hard to mistake for each other.
    case atkinson
    /// OpenDyslexic: heavier letter bottoms that help keep letters from flipping and swapping.
    case openDyslexic

    static let key = "reading.font"

    var id: String { rawValue }

    static var current: ReadingFont {
        ReadingFont(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// The font names are brands and stay as they are in every language.
    var name: Text {
        switch self {
        case .system: Text("System")
        case .atkinson: Text(verbatim: "Atkinson Hyperlegible")
        case .openDyslexic: Text(verbatim: "OpenDyslexic")
        }
    }

    /// The font a script is actually read in. A script with Latin, Greek or Cyrillic letters this
    /// font lacks (Atkinson has no Vietnamese tone marks, say) would come out in two fonts letter
    /// by letter, so it gets the system font instead.
    func resolved(for text: String) -> ReadingFont {
        guard self != .system, !text.isEmpty else { return self }
        let key = "\(rawValue)|\(text.hashValue)"
        if let known = Self.coverage.withLock({ $0[key] }) { return known ? self : .system }
        let font = platformFont(size: 17) as CTFont
        var covers = true
        for scalar in text.unicodeScalars.prefix(4000) where Self.needsMatchingLetters(scalar) {
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            if !CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) {
                covers = false
                break
            }
        }
        let result = covers
        Self.coverage.withLock { cache in
            if cache.count > 64 { cache.removeAll() }
            cache[key] = result
        }
        return result ? self : .system
    }

    /// Whether a font covers a script, by font name and the script's hash.
    private static let coverage = OSAllocatedUnfairLock(initialState: [String: Bool]())

    /// Letters of the alphabets these fonts draw at least in part: accented Latin, Greek, Cyrillic.
    /// Plain ASCII is always there; other alphabets fall back to the system font a word at a time.
    private static func needsMatchingLetters(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00C0...0x024F, 0x1E00...0x1EFF: true   // Latin with accents, including Vietnamese
        case 0x0370...0x03FF, 0x0400...0x04FF: true   // Greek, Cyrillic
        default: false
        }
    }

    /// The three weights the reading views use.
    enum Weight: Sendable {
        case regular, semibold, heavy
    }

    /// SwiftUI font for script text. Sizes are fixed: the reader sets them with the size slider.
    func font(size: CGFloat, weight: Weight = .regular, italic: Bool = false) -> Font {
        guard let name = postScriptName(weight: weight, italic: italic) else {
            let font = Font.system(size: size, weight: weight.systemWeight)
            return italic ? font.italic() : font
        }
        return .custom(name, fixedSize: size)
    }

    #if canImport(UIKit)
    typealias PlatformFont = UIFont
    #else
    typealias PlatformFont = NSFont
    #endif

    /// The same face as `font(size:weight:italic:)`, for measuring text.
    func platformFont(size: CGFloat, weight: Weight = .regular, italic: Bool = false) -> PlatformFont {
        if let name = postScriptName(weight: weight, italic: italic),
           let font = PlatformFont(name: name, size: size) {
            return font
        }
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: size, weight: weight.platformWeight)
        if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return font
        #else
        let font = NSFont.systemFont(ofSize: size, weight: weight.platformWeight)
        if italic {
            return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
        }
        return font
        #endif
    }

    private func postScriptName(weight: Weight, italic: Bool) -> String? {
        switch self {
        case .system:
            return nil
        case .atkinson:
            let face: String
            switch weight {
            case .regular: face = italic ? "Italic" : "Regular"
            case .semibold: face = italic ? "SemiBoldItalic" : "SemiBold"
            case .heavy: face = italic ? "ExtraBoldItalic" : "ExtraBold"
            }
            return "AtkinsonHyperlegibleNext-" + face
        case .openDyslexic:
            // Its regular is already as dark as most semibolds, so only bold text steps up.
            switch (weight == .heavy, italic) {
            case (false, false): return "OpenDyslexic-Regular"
            case (false, true): return "OpenDyslexic-Italic"
            case (true, false): return "OpenDyslexic-Bold"
            case (true, true): return "OpenDyslexic-BoldItalic"
            }
        }
    }

    // MARK: - Registration

    /// Makes the bundled fonts available to this process, on iPhone, iPad and Mac alike.
    static func registerBundledFonts() {
        _ = registration
    }

    private static let registration: Void = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

private extension ReadingFont.Weight {
    var systemWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .semibold: .semibold
        case .heavy: .heavy
        }
    }

    var platformWeight: ReadingFont.PlatformFont.Weight {
        switch self {
        case .regular: .regular
        case .semibold: .semibold
        case .heavy: .heavy
        }
    }
}

/// Extra room between letters and words. Wider spacing helps many readers with dyslexia
/// keep letters apart and find where each word ends.
enum LetterSpacing: Int, CaseIterable, Identifiable, Sendable {
    case normal, wide, extraWide

    static let key = "reading.letterSpacing"

    var id: Int { rawValue }

    var name: Text {
        switch self {
        case .normal: Text("Normal")
        case .wide: Text("Wide")
        case .extraWide: Text("Extra Wide")
        }
    }

    /// Space added after each letter, in points, for text of this size. Text in scripts whose
    /// letters join or carry stacked marks keeps its natural spacing.
    func tracking(for size: CGFloat, in text: some StringProtocol) -> CGFloat {
        Self.suits(text) ? tracking(for: size) : 0
    }

    /// Space added after each letter, in points, for text of this size.
    func tracking(for size: CGFloat) -> CGFloat {
        switch self {
        case .normal: 0
        case .wide: size * 0.06
        case .extraWide: size * 0.12
        }
    }

    /// False for text in scripts that letter spacing would damage: it pulls apart Arabic's joined
    /// letters and moves the vowel and tone marks of Thai and Indic scripts off their letters.
    static func suits(_ text: some StringProtocol) -> Bool {
        !text.unicodeScalars.prefix(2000).contains { scalar in
            switch scalar.value {
            case 0x0600...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: true   // Arabic, Syriac, Thaana, N'Ko
            case 0x0900...0x0DFF: true                                     // Indic scripts
            case 0x0E00...0x0EFF, 0x0F00...0x0FFF: true                    // Thai, Lao, Tibetan
            case 0x1000...0x109F, 0x1780...0x17FF: true                    // Myanmar, Khmer
            default: false
            }
        }
    }

    /// Space added between words on top of the letters' own, in points.
    func wordGap(for size: CGFloat) -> CGFloat {
        switch self {
        case .normal: 0
        case .wide: size * 0.15
        case .extraWide: size * 0.3
        }
    }
}
