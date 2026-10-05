//
//  Extensions.swift
//  yprompt
//

import SwiftUI

// MARK: - Color Hex
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }

    func toHex() -> String {
        #if canImport(UIKit)
        let c = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        return "#000000"
        #endif
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Date Formatting
extension Date {
    var shortFormatted: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: self)
    }
}

// MARK: - TextAlignment from Int
extension Int {
    var textAlignment: TextAlignment {
        switch self {
        case 1: return .center
        case 2: return .trailing
        default: return .leading
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case 1: return .center
        case 2: return .trailing
        default: return .leading
        }
    }
}

// MARK: - Keyboard Dismiss
extension View {
    func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        #endif
    }
}

// MARK: - Glass / scroll-edge APIs
// Liquid Glass needs iOS / macOS 26. visionOS and older systems get material and bordered fallbacks.
extension View {
    /// Soft top scroll-edge effect where available.
    @ViewBuilder
    func ypScrollEdgeEffect() -> some View {
        #if os(visionOS)
        self
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
        #endif
    }

    /// Glass prominent button style, falling back to bordered prominent.
    @ViewBuilder
    func ypGlassProminentButtonStyle() -> some View {
        #if os(visionOS)
        self.buttonStyle(.borderedProminent)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #endif
    }

    /// Plain glass button style, falling back to bordered.
    @ViewBuilder
    func ypGlassButtonStyle() -> some View {
        #if os(visionOS)
        self.buttonStyle(.bordered)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #endif
    }

    /// Default glass fill in a rounded rect; material fallback.
    @ViewBuilder
    func ypGlassEffect(cornerRadius: CGFloat) -> some View {
        #if os(visionOS)
        self.background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
        }
        #endif
    }

    /// Interactive glass (optionally accent-tinted); material fallback.
    @ViewBuilder
    func ypGlassEffect(cornerRadius: CGFloat, highlighted: Bool) -> some View {
        #if os(visionOS)
        self.ypMaterialCard(cornerRadius: cornerRadius, highlighted: highlighted)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            if highlighted {
                self.glassEffect(.regular.tint(.accentColor).interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self.ypMaterialCard(cornerRadius: cornerRadius, highlighted: highlighted)
        }
        #endif
    }

    private func ypMaterialCard(cornerRadius: CGFloat, highlighted: Bool) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.ultraThinMaterial)
                .overlay {
                    if highlighted {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: cornerRadius)
                                    .fill(Color.accentColor.opacity(0.1))
                            )
                    }
                }
        }
    }
}

extension View {
    /// Navigation subtitle where available (iOS / macOS 26); nothing on older systems.
    @ViewBuilder
    func ypNavigationSubtitle(_ subtitle: String) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}

// MARK: - Font traits without a resolution context
extension Font {
    /// Bold / italic as applied by the editor's formatting actions, detected by value equality.
    /// Works on every OS version and outside SwiftUI rendering, unlike `Font.resolve(in:)`.
    var ypEditorTraits: (isBold: Bool, isItalic: Bool) {
        let boldItalic = self == Font.body.bold().italic() || self == Font.body.italic().bold()
        return (boldItalic || self == Font.body.bold(), boldItalic || self == Font.body.italic())
    }
}

// MARK: - Haptics (no-op on visionOS)
enum YPHaptics {
    static func light() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func medium() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}
