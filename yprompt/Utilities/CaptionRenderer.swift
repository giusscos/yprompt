//
//  CaptionRenderer.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import CoreImage
import CoreText
import UIKit

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
    private let fontSize: CGFloat
    private let ascent: CGFloat
    private let descent: CGFloat
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// - Parameter size: the video as shown (upright), in pixels.
    init(lines captionLines: [CaptionLine], style: CaptionStyle, position: CaptionPosition, size: CGSize) {
        self.style = style
        let shortSide = min(size.width, size.height)
        fontSize = max(12, (shortSide * 0.068).rounded())
        let font = Self.font(size: fontSize)
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)

        let rowHeight = ((ascent + descent) * 1.15).rounded(.up)
        let padding = (fontSize * 0.5).rounded()
        let maxWidth = size.width * 0.86
        // A little wider than a plain space, so a word growing as it's said doesn't touch the next.
        let spaceWidth = (Self.makeLine(" ", font: font).width * 1.2).rounded()
        let isPortrait = size.height > size.width

        var built: [Line] = []
        for caption in captionLines where style != .off {
            // Wrap the words into rows that fit the frame.
            var rows: [[(line: CTLine, width: CGFloat, start: Double)]] = [[]]
            var rowWidth: CGFloat = 0
            for word in caption.words {
                let measured = Self.makeLine(word.text, font: font)
                let isRowEmpty = rows[rows.count - 1].isEmpty
                let widened = isRowEmpty ? measured.width : rowWidth + spaceWidth + measured.width
                if widened > maxWidth && !isRowEmpty {
                    rows.append([(measured.line, measured.width, word.start)])
                    rowWidth = measured.width
                } else {
                    rows[rows.count - 1].append((measured.line, measured.width, word.start))
                    rowWidth = widened
                }
            }

            let blockHeight = CGFloat(rows.count) * rowHeight
            // Top of the text, measured from the top of the frame.
            let top: CGFloat = switch position {
            case .bottom: size.height * (isPortrait ? 0.80 : 0.90) - blockHeight
            case .middle: (size.height - blockHeight) / 2
            }
            let rowWidths = rows.map { row in row.reduce(0) { $0 + $1.width } + spaceWidth * CGFloat(max(0, row.count - 1)) }
            let rowLefts = rowWidths.map { ((size.width - $0) / 2).rounded() }
            let left = (rowLefts.min() ?? 0) - padding
            let right = zip(rowLefts, rowWidths).map { $0 + $1 }.max() ?? size.width
            let stripWidth = (right + padding - left).rounded(.up)
            let stripHeight = (blockHeight + padding * 2).rounded(.up)
            let strip = CGRect(x: left, y: size.height - (top - padding) - stripHeight,
                               width: stripWidth, height: stripHeight)

            var words: [Word] = []
            for (rowIndex, row) in rows.enumerated() {
                var x = rowLefts[rowIndex] - left
                let rowTop = padding + CGFloat(rowIndex) * rowHeight
                let baseline = stripHeight - (rowTop + (rowHeight - ascent - descent) / 2 + ascent)
                for item in row {
                    words.append(Word(line: item.line, width: item.width, start: item.start,
                                      origin: CGPoint(x: x, y: baseline)))
                    x += item.width + spaceWidth
                }
            }
            built.append(Line(start: caption.start, end: caption.end, words: words, strip: strip.integral))
        }
        lines = built
    }

    /// The caption at `time` (in the take's own time), and where it goes in the frame.
    func image(at time: Double) -> (image: CGImage, origin: CGPoint)? {
        guard let line = lines.first(where: { $0.start <= time && time < $0.end }) else { return nil }
        let width = Int(line.strip.width), height = Int(line.strip.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Fade in at the first word and out when the next caption takes over.
        let fade = min(0.08, (line.end - line.start) / 4)
        let lineAlpha = min(1, max(0, min((time - line.start) / fade, (line.end - time) / fade)))
        context.setAlpha(CGFloat(lineAlpha))
        context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.3,
                          color: CGColor(gray: 0, alpha: 0.6))

        for word in line.words {
            var alpha: CGFloat = 1
            var scale: CGFloat = 1
            if style == .lyrics {
                // Like Lyrics Style: the line waits dimmed, and each word lights up as it's said.
                let since = time - word.start
                alpha = 0.5 + 0.5 * CGFloat(min(max(since / 0.12, 0), 1))
                if since > 0 && since < 0.3 { scale = 1 + 0.08 * CGFloat(sin(.pi * since / 0.3)) }
            }
            context.saveGState()
            if scale != 1 {
                let center = CGPoint(x: word.origin.x + word.width / 2, y: word.origin.y + (ascent - descent) / 2)
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -center.x, y: -center.y)
            }
            context.setFillColor(CGColor(gray: 1, alpha: alpha))
            context.textPosition = word.origin
            CTLineDraw(word.line, context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        return (image, line.strip.origin)
    }

    // MARK: - Text

    private static func font(size: CGFloat) -> CTFont {
        let base = UIFont.systemFont(ofSize: size, weight: .heavy)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size) as CTFont
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
