//
//  WordTeleprompterView.swift
//  yprompt
//

#if !os(watchOS)
import SwiftUI

#if canImport(UIKit)
private typealias PlatformFont = UIFont
#else
private typealias PlatformFont = NSFont
#endif

// MARK: - Layout

/// The script's words broken into lines for a given width and font.
struct WordLayout: Equatable {
    struct Placement: Equatable {
        var x: CGFloat
        var width: CGFloat
        var line: Int
        /// Below 1 for a word too wide for the line on its own.
        var scale: CGFloat
    }

    struct Line: Equatable {
        var words: Range<Int>
        var y: CGFloat
    }

    struct Key: Equatable {
        var width: CGFloat
        var fontSize: CGFloat
        var lineHeightMultiple: CGFloat
        var alignment: Int
        var horizontalPadding: CGFloat
        var textHash: Int
    }

    var key: Key
    var placements: [Placement] = []
    var lines: [Line] = []
    var lineHeight: CGFloat = 0
    var lineStep: CGFloat = 1

    static let baseWeight = Font.Weight.semibold
    static let boldWeight = Font.Weight.heavy

    init(words: ScriptWords, key: Key) {
        self.key = key
        let available = max(40, key.width - key.horizontalPadding * 2)
        var fonts: [ScriptWord.Style: PlatformFont] = [:]
        var widths: [String: CGFloat] = [:]

        func measure(_ word: ScriptWord) -> CGFloat {
            let cacheKey = "\(word.style.isBold ? 1 : 0)\(word.style.isItalic ? 1 : 0)\(word.text)"
            if let known = widths[cacheKey] { return known }
            var trackedStyle = ScriptWord.Style()
            trackedStyle.isBold = word.style.isBold
            trackedStyle.isItalic = word.style.isItalic
            let font = fonts[trackedStyle] ?? Self.platformFont(size: key.fontSize, style: trackedStyle)
            fonts[trackedStyle] = font
            let width = ceil((word.text as NSString).size(withAttributes: [.font: font]).width)
            widths[cacheKey] = width
            return width
        }

        let baseFont = Self.platformFont(size: key.fontSize, style: .init())
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width
        lineHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        lineStep = lineHeight + (key.lineHeightMultiple - 1.0) * key.fontSize * 0.5 + key.fontSize * 0.12

        placements.reserveCapacity(words.count)
        var y: CGFloat = 0
        var lineStart = 0
        var x: CGFloat = 0

        func closeLine(upTo end: Int) {
            guard end > lineStart else { return }
            let last = placements[end - 1]
            let used = last.x + last.width * last.scale
            let inset: CGFloat
            switch key.alignment {
            case 1: inset = (available - used) / 2
            case 2: inset = available - used
            default: inset = 0
            }
            for index in lineStart..<end {
                placements[index].x += key.horizontalPadding + max(0, inset)
            }
            lines.append(Line(words: lineStart..<end, y: y))
            lineStart = end
        }

        for (index, word) in words.words.enumerated() {
            let width = measure(word)
            let scale = min(1, available / max(width, 1))
            let scaled = width * scale
            if x > 0, x + scaled > available {
                closeLine(upTo: index)
                y += lineStep
                x = 0
            }
            placements.append(Placement(x: x, width: width, line: lines.count, scale: scale))
            x += scaled + (word.spaceAfter ? spaceWidth : 0)
            if word.breaksAfter > 0, index < words.count - 1 {
                closeLine(upTo: index + 1)
                y += lineStep * (word.breaksAfter > 1 ? 1.5 : 1)
                x = 0
            }
        }
        closeLine(upTo: words.count)
    }

    private static func platformFont(size: CGFloat, style: ScriptWord.Style) -> PlatformFont {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: size, weight: style.isBold ? .heavy : .semibold)
        if style.isItalic, let italic = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: italic, size: size)
        }
        return font
        #else
        let font = NSFont.systemFont(ofSize: size, weight: style.isBold ? .heavy : .semibold)
        if style.isItalic {
            let italic = font.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: italic, size: size) ?? font
        }
        return font
        #endif
    }

    /// Last line starting at or above `y`.
    func lineIndex(atOrAbove y: CGFloat) -> Int {
        var low = 0
        var high = lines.count - 1
        var found = 0
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].y <= y {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }
}

// MARK: - Scroll motion

/// A spring following the current line. Lines further down read it slightly later,
/// which gives the staggered settle of Apple Music lyrics.
private final class WordScrollMotion {
    private var offset: Double?
    private var velocity = 0.0
    private var lastTime: TimeInterval?
    private var history: [(time: TimeInterval, offset: Double)] = []

    private static let stiffness = 110.0
    private static let damping = 19.0
    private static let historySeconds = 0.5

    func advance(to target: Double, at time: TimeInterval) {
        guard var current = offset, let last = lastTime else {
            offset = target
            lastTime = time
            history = [(time, target)]
            return
        }
        var remaining = min(max(0, time - last), 0.1)
        lastTime = time
        while remaining > 0 {
            let step = min(remaining, 1.0 / 120.0)
            velocity += (Self.stiffness * (target - current) - Self.damping * velocity) * step
            current += velocity * step
            remaining -= step
        }
        if abs(target - current) < 0.05, abs(velocity) < 0.05 {
            current = target
            velocity = 0
        }
        offset = current
        history.append((time, current))
        if let first = history.first, time - first.time > Self.historySeconds {
            history.removeFirst(min(history.count - 1, 16))
        }
    }

    /// Where the spring was `delay` seconds ago.
    func value(delayedBy delay: TimeInterval) -> Double {
        guard delay > 0, let time = lastTime else { return offset ?? 0 }
        let wanted = time - delay
        for sample in history.reversed() where sample.time <= wanted {
            return sample.offset
        }
        return history.first?.offset ?? offset ?? 0
    }
}

// MARK: - View

/// Draws the script line by line. Each word fills as it's read, like Apple Music's lyrics:
/// a soft edge moves across it and it lifts a little, while the current line grows and
/// the lines settle into place. Upcoming lines stay sharp, because a reader needs to see ahead.
struct WordTeleprompterView: View {
    let viewModel: TeleprompterViewModel
    let words: ScriptWords
    var fontSize: CGFloat
    var lineHeightMultiple: CGFloat = 1.4
    var textColor: Color
    var alignment: Int = 0
    var horizontalPadding: CGFloat = 16
    /// Keep text clear of this much space at the top and bottom.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// Where the current line rests within the space left: 0 is the top.
    var anchor: CGFloat = 0.2
    var isMirrored: Bool = false
    /// Opacity of text still to be read.
    var upcomingOpacity: Double = 0.42
    /// Opacity of lines already read.
    var pastOpacity: Double = 0.22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layout: WordLayout?
    @State private var motion = WordScrollMotion()
    @State private var isSettling = true
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            // Read out here: inside the Canvas a new layout wouldn't trigger a redraw.
            let currentLayout = layout
            TimelineView(.animation(paused: !viewModel.isPlaying && !isSettling)) { timeline in
                Canvas { context, size in
                    // A queue moves to the next script a moment before its layout is ready.
                    if let currentLayout, currentLayout.key.textHash == words.textHash {
                        draw(in: context, size: size, layout: currentLayout,
                             time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
            .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
            .onChange(of: layoutKey(width: geo.size.width), initial: true) { _, key in
                guard key.width > 0 else { return }
                layout = WordLayout(words: words, key: key)
                settle()
            }
        }
        .onChange(of: viewModel.wordIndex) { settle() }
        .onChange(of: viewModel.isPlaying) { settle() }
        .onDisappear { settleTask?.cancel() }
        .accessibilityElement()
        .accessibilityLabel(Text(words.text))
    }

    private func layoutKey(width: CGFloat) -> WordLayout.Key {
        WordLayout.Key(
            width: width,
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            alignment: alignment,
            horizontalPadding: horizontalPadding,
            textHash: words.textHash
        )
    }

    /// Keeps drawing long enough for the spring to come to rest after a change while paused.
    private func settle() {
        isSettling = true
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            isSettling = false
        }
    }

    // MARK: - Drawing

    private func draw(in context: GraphicsContext, size: CGSize, layout: WordLayout, time: TimeInterval) {
        guard !layout.lines.isEmpty else { return }
        let position = viewModel.wordPosition
        let currentWord = min(Int(position), layout.placements.count - 1)
        let currentLine = layout.placements[currentWord].line

        motion.advance(to: Double(layout.lines[currentLine].y), at: time)
        let settled = motion.value(delayedBy: 0)

        let readable = max(0, size.height - topInset - bottomInset)
        let restY = topInset + readable * anchor
        let lineStep = layout.lineStep

        let firstVisible = layout.lineIndex(atOrAbove: CGFloat(settled) - restY - lineStep)
        for lineIndex in firstVisible..<layout.lines.count {
            let line = layout.lines[lineIndex]
            let distance = lineIndex - currentLine
            let delay = (distance > 0 && !reduceMotion) ? Double(min(distance, 8)) * 0.035 : 0
            let y = restY + line.y - CGFloat(motion.value(delayedBy: delay))
            // Nothing below the player panel, which doesn't reach the bottom edge.
            if y > size.height - bottomInset { break }

            // 1 while this line sits at the resting place, falling to 0 a line away.
            let emphasis = max(0, 1 - abs(Double(line.y) - settled) / Double(lineStep))
            drawLine(line, y: y, emphasis: emphasis, position: position, layout: layout, in: context)
        }
    }

    private func drawLine(
        _ line: WordLayout.Line,
        y: CGFloat,
        emphasis: Double,
        position: Double,
        layout: WordLayout,
        in context: GraphicsContext
    ) {
        var lineContext = context
        if !reduceMotion {
            // The current line grows from its aligned edge.
            let scale = 0.97 + 0.03 * emphasis
            let edge: CGFloat
            switch alignment {
            case 1: edge = layout.key.width / 2
            case 2: edge = layout.key.width - layout.key.horizontalPadding
            default: edge = layout.key.horizontalPadding
            }
            let midY = y + layout.lineHeight / 2
            lineContext.translateBy(x: edge, y: midY)
            lineContext.scaleBy(x: scale, y: scale)
            lineContext.translateBy(x: -edge, y: -midY)
        }

        for index in line.words {
            drawWord(words.words[index], placement: layout.placements[index], y: y,
                     fill: min(max(position - Double(index), 0), 1),
                     emphasis: emphasis, height: layout.lineHeight, in: lineContext)
        }
    }

    private func drawWord(
        _ word: ScriptWord,
        placement: WordLayout.Placement,
        y: CGFloat,
        fill: Double,
        emphasis: Double,
        height: CGFloat,
        in context: GraphicsContext
    ) {
        var wordContext = context
        // Filled words rise slightly while their line is current.
        let eased = fill * fill * (3 - 2 * fill)
        let lift = reduceMotion ? 0 : CGFloat(eased * emphasis) * fontSize * 0.05
        wordContext.translateBy(x: placement.x, y: y - lift)
        if placement.scale < 1 {
            wordContext.scaleBy(x: placement.scale, y: placement.scale)
        }

        var text = Text(word.text)
            .font(.system(size: fontSize, weight: word.style.isBold ? WordLayout.boldWeight : WordLayout.baseWeight))
        if word.style.isItalic { text = text.italic() }
        if word.style.isUnderlined { text = text.underline() }
        if word.style.isStruckThrough { text = text.strikethrough() }
        var resolved = wordContext.resolve(text)

        if fill >= 1 {
            resolved.shading = .color(textColor.opacity(pastOpacity + (1 - pastOpacity) * emphasis))
            wordContext.draw(resolved, at: .zero, anchor: .topLeading)
            return
        }

        resolved.shading = .color(textColor.opacity(upcomingOpacity))
        wordContext.draw(resolved, at: .zero, anchor: .topLeading)
        guard fill > 0 else { return }

        // A soft edge moves across the word, revealing it at full brightness.
        let softness = fontSize * 0.7
        let head = CGFloat(fill) * (placement.width + softness)
        var bright = resolved
        bright.shading = .color(textColor)
        wordContext.drawLayer { layer in
            layer.clipToLayer { mask in
                mask.fill(
                    Path(CGRect(x: -4, y: -4, width: placement.width + 8, height: height + 8)),
                    with: .linearGradient(
                        Gradient(colors: [.black, .clear]),
                        startPoint: CGPoint(x: head - softness, y: 0),
                        endPoint: CGPoint(x: head, y: 0)
                    )
                )
            }
            layer.draw(bright, at: .zero, anchor: .topLeading)
        }
    }
}
#endif
