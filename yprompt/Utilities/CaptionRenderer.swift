//
//  CaptionRenderer.swift
//  yprompt
//

#if os(iOS) || os(macOS)
import AVFoundation
import CoreImage
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

nonisolated enum CaptionStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case off, lyrics, clean
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .lyrics: "Lyrics"
        case .clean: "Clean"
        }
    }
}

nonisolated enum CaptionPosition: String, CaseIterable, Identifiable, Codable, Sendable {
    case bottom, middle
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .bottom: "Bottom"
        case .middle: "Middle"
        }
    }
}

nonisolated enum CaptionFont: String, CaseIterable, Identifiable, Codable, Sendable {
    case rounded, classic, serif, mono
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .rounded: "Rounded"
        case .classic: "Classic"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }
}

nonisolated enum CaptionSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case small, medium, large
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 0.8
        case .medium: 1
        case .large: 1.25
        }
    }
}

nonisolated enum CaptionColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case white, black, yellow, orange, red, pink, cyan, green
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .white: "White"
        case .black: "Black"
        case .yellow: "Yellow"
        case .orange: "Orange"
        case .red: "Red"
        case .pink: "Pink"
        case .cyan: "Blue"
        case .green: "Green"
        }
    }

    var rgb: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .white: (1, 1, 1)
        case .black: (0, 0, 0)
        case .yellow: (1, 0.84, 0.04)
        case .orange: (1, 0.62, 0.04)
        case .red: (1, 0.27, 0.23)
        case .pink: (1, 0.25, 0.6)
        case .cyan: (0.39, 0.82, 1)
        case .green: (0.19, 0.82, 0.35)
        }
    }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        let rgb = rgb
        return CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }
}

nonisolated enum CaptionBackground: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The words alone, with a soft shadow.
    case none
    /// A line around each letter.
    case outline
    /// A rounded box behind the caption.
    case box
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .none: "None"
        case .outline: "Outline"
        case .box: "Box"
        }
    }
}

/// How captions look: font, size, colors and what's behind them. The default is the look
/// captions had before it could be changed.
nonisolated struct CaptionLook: Codable, Hashable, Sendable {
    var font: CaptionFont = .rounded
    var size: CaptionSize = .medium
    var textColor: CaptionColor = .white
    /// The word being said, in Lyrics. The same as the text color shows no difference.
    var highlightColor: CaptionColor = .white
    var background: CaptionBackground = .none
    /// The box, or the outline around the letters.
    var backgroundColor: CaptionColor = .black
    var allCaps = false

    init() {}

    /// Each choice on its own, so a look saved by a later version still opens with what it can read.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptionLook()
        font = (try? container.decodeIfPresent(CaptionFont.self, forKey: .font)) ?? defaults.font
        size = (try? container.decodeIfPresent(CaptionSize.self, forKey: .size)) ?? defaults.size
        textColor = (try? container.decodeIfPresent(CaptionColor.self, forKey: .textColor)) ?? defaults.textColor
        highlightColor = (try? container.decodeIfPresent(CaptionColor.self, forKey: .highlightColor)) ?? defaults.highlightColor
        background = (try? container.decodeIfPresent(CaptionBackground.self, forKey: .background)) ?? defaults.background
        backgroundColor = (try? container.decodeIfPresent(CaptionColor.self, forKey: .backgroundColor)) ?? defaults.backgroundColor
        allCaps = (try? container.decodeIfPresent(Bool.self, forKey: .allCaps)) ?? defaults.allCaps
    }

    /// The last look chosen, which new recordings start with.
    static var lastUsed: CaptionLook? {
        get {
            UserDefaults.standard.data(forKey: ReadingPreferences.takeCaptionLookKey)
                .flatMap { try? JSONDecoder().decode(CaptionLook.self, from: $0) }
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: ReadingPreferences.takeCaptionLookKey) }
    }
}

/// Draws the caption for any moment of a take. The review sheet's player and the saved
/// video both use it, through the same video composition, so what's previewed is what's saved.
/// Everything it holds is immutable, so frames can be drawn on any thread.
nonisolated final class CaptionRenderer: @unchecked Sendable {
    private struct Word {
        let line: CTLine
        let width: CGFloat
        let start: Double
        /// Left end of the baseline, in the strip's coordinates (origin bottom left).
        let origin: CGPoint
    }

    private struct Line {
        let start: Double
        let end: Double
        let words: [Word]
        /// Where the line's image goes in the frame (origin bottom left).
        let strip: CGRect
    }

    private let lines: [Line]
    private let style: CaptionStyle
    private let look: CaptionLook
    private let fontSize: CGFloat
    private let ascent: CGFloat
    private let descent: CGFloat
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Recently drawn captions. A caption looks the same for most of the time it's on screen,
    /// so the preview and the export reuse the image instead of drawing it every frame.
    private let cacheLock = NSLock()
    private var cache: [Int: CGImage] = [:]

    /// Lyrics lights the word being said in its own color, when one is chosen.
    private var highlightsWord: Bool { style == .lyrics && look.highlightColor != look.textColor }

    /// - Parameter size: the video as shown (upright), in pixels.
    init(lines captionLines: [CaptionLine], style: CaptionStyle, position: CaptionPosition,
         look: CaptionLook = CaptionLook(), size: CGSize) {
        self.style = style
        self.look = look
        let shortSide = min(size.width, size.height)
        fontSize = max(12, (shortSide * 0.068 * look.size.scale).rounded())
        let font = Self.font(size: fontSize, design: look.font)
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)

        let rowHeight = ((ascent + descent) * 1.15).rounded(.up)
        // Room around the words for the shadow or outline; a box hugs them a little closer.
        let paddingX = (fontSize * (look.background == .box ? 0.45 : 0.5)).rounded()
        let paddingY = (fontSize * (look.background == .box ? 0.25 : 0.5)).rounded()
        let maxWidth = size.width * 0.86
        // A little wider than a plain space, so a word growing as it's said doesn't touch the next.
        let spaceWidth = (Self.makeLine(" ", font: font).width * 1.2).rounded()
        let isPortrait = size.height > size.width

        var built: [Line] = []
        for caption in captionLines where style != .off {
            // Wrap the words into rows that fit the frame.
            // `gap` is the space before the next word: none after a word joined to it.
            var rows: [[(line: CTLine, width: CGFloat, start: Double, gap: CGFloat)]] = [[]]
            var rowWidth: CGFloat = 0
            for word in caption.words {
                let text = look.allCaps ? word.text.uppercased(with: .current) : word.text
                let measured = Self.makeLine(text, font: font)
                let gap = word.joinsNext ? 0 : spaceWidth
                let previousGap = rows[rows.count - 1].last?.gap
                let widened = previousGap.map { rowWidth + $0 + measured.width } ?? measured.width
                // Never wrap between two joined words.
                if widened > maxWidth, let previousGap, previousGap > 0 {
                    rows.append([(measured.line, measured.width, word.start, gap)])
                    rowWidth = measured.width
                } else {
                    rows[rows.count - 1].append((measured.line, measured.width, word.start, gap))
                    rowWidth = widened
                }
            }

            let blockHeight = CGFloat(rows.count) * rowHeight
            // Top of the text, measured from the top of the frame.
            let top: CGFloat = switch position {
            case .bottom: size.height * (isPortrait ? 0.80 : 0.90) - blockHeight
            case .middle: (size.height - blockHeight) / 2
            }
            let rowWidths = rows.map { row in row.reduce(0) { $0 + $1.width } + row.dropLast().reduce(0) { $0 + $1.gap } }
            let rowLefts = rowWidths.map { ((size.width - $0) / 2).rounded() }
            let left = (rowLefts.min() ?? 0) - paddingX
            let right = zip(rowLefts, rowWidths).map { $0 + $1 }.max() ?? size.width
            let stripWidth = (right + paddingX - left).rounded(.up)
            let stripHeight = (blockHeight + paddingY * 2).rounded(.up)
            let strip = CGRect(x: left, y: size.height - (top - paddingY) - stripHeight,
                               width: stripWidth, height: stripHeight)

            var words: [Word] = []
            for (rowIndex, row) in rows.enumerated() {
                var x = rowLefts[rowIndex] - left
                let rowTop = paddingY + CGFloat(rowIndex) * rowHeight
                let baseline = stripHeight - (rowTop + (rowHeight - ascent - descent) / 2 + ascent)
                for item in row {
                    words.append(Word(line: item.line, width: item.width, start: item.start,
                                      origin: CGPoint(x: x, y: baseline)))
                    x += item.width + item.gap
                }
            }
            built.append(Line(start: caption.start, end: caption.end, words: words, strip: strip.integral))
        }
        lines = built
    }

    /// The caption at `time` (in the take's own time), and where it goes in the frame.
    func image(at time: Double) -> (image: CGImage, origin: CGPoint)? {
        guard let index = lines.firstIndex(where: { $0.start <= time && time < $0.end }) else { return nil }
        let line = lines[index]

        // Fade in at the first word and out when the next caption takes over.
        let fade = min(0.08, (line.end - line.start) / 4)
        let lineAlpha = min(1, max(0, min((time - line.start) / fade, (line.end - time) / fade)))
        // The word being said: the last one to have started.
        let current = highlightsWord ? line.words.lastIndex { $0.start <= time } : nil
        let states = line.words.map { wordState($0, at: time) }

        // Steps fine enough not to show, coarse enough that most frames reuse an image.
        var hasher = Hasher()
        hasher.combine(index)
        hasher.combine(Int((lineAlpha * 20).rounded()))
        hasher.combine(current)
        for state in states {
            hasher.combine(Int((state.alpha * 20).rounded()))
            hasher.combine(Int((state.scale * 200).rounded()))
        }
        let key = hasher.finalize()
        if let cached = cacheLock.withLock({ cache[key] }) {
            return (cached, line.strip.origin)
        }

        let width = Int(line.strip.width), height = Int(line.strip.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setAlpha(CGFloat(lineAlpha))

        switch look.background {
        case .none:
            context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.3,
                              color: CGColor(gray: 0, alpha: 0.6))
        case .box:
            let corner = min(fontSize * 0.35, CGFloat(height) / 2)
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                                   cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.setFillColor(look.backgroundColor.cgColor(alpha: 0.78))
            context.fillPath()
        case .outline:
            context.setLineJoin(.round)
            context.setLineWidth(fontSize * 0.16)
        }

        for (wordIndex, (word, state)) in zip(line.words, states).enumerated() {
            let alpha = state.alpha
            let scale = state.scale
            context.saveGState()
            if scale != 1 {
                let center = CGPoint(x: word.origin.x + word.width / 2, y: word.origin.y + (ascent - descent) / 2)
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -center.x, y: -center.y)
            }
            if look.background == .outline {
                // The outline first, twice as wide as it shows: the letters cover its inner half.
                context.setTextDrawingMode(.stroke)
                context.setStrokeColor(look.backgroundColor.cgColor(alpha: alpha))
                context.textPosition = word.origin
                CTLineDraw(word.line, context)
                context.setTextDrawingMode(.fill)
            }
            let color = wordIndex == current ? look.highlightColor : look.textColor
            context.setFillColor(color.cgColor(alpha: alpha))
            context.textPosition = word.origin
            CTLineDraw(word.line, context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        cacheLock.withLock {
            if cache.count > 96 { cache.removeAll(keepingCapacity: true) }
            cache[key] = image
        }
        return (image, line.strip.origin)
    }

    /// How a word looks at a moment: Lyrics dims it until it's said, then lights it up with a
    /// small pop, like Lyrics Style while reading.
    private func wordState(_ word: Word, at time: Double) -> (alpha: CGFloat, scale: CGFloat) {
        guard style == .lyrics else { return (1, 1) }
        let since = time - word.start
        let alpha = 0.5 + 0.5 * CGFloat(min(max(since / 0.12, 0), 1))
        let scale = since > 0 && since < 0.3 ? 1 + 0.08 * CGFloat(sin(.pi * since / 0.3)) : 1
        return (alpha, scale)
    }

    // MARK: - Text

    private static func font(size: CGFloat, design: CaptionFont) -> CTFont {
        #if os(macOS)
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        let systemDesign: NSFontDescriptor.SystemDesign = switch design {
        case .rounded: .rounded
        case .classic: .default
        case .serif: .serif
        case .mono: .monospaced
        }
        let descriptor = base.fontDescriptor.withDesign(systemDesign) ?? base.fontDescriptor
        return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
        #else
        let base = UIFont.systemFont(ofSize: size, weight: .heavy)
        let systemDesign: UIFontDescriptor.SystemDesign = switch design {
        case .rounded: .rounded
        case .classic: .default
        case .serif: .serif
        case .mono: .monospaced
        }
        let descriptor = base.fontDescriptor.withDesign(systemDesign) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size) as CTFont
        #endif
    }

    /// A run of text that takes its color from the context, so one line serves every state.
    private static func makeLine(_ text: String, font: CTFont) -> (line: CTLine, width: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)
        return (line, width)
    }
}

#endif
