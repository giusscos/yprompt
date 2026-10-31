//
//  ScriptWords.swift
//  yprompt
//

import Foundation

/// One word of a script: what is drawn on screen and what is matched against speech.
struct ScriptWord: Equatable {
    struct Style: Hashable {
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isStruckThrough = false
    }

    /// The word with its punctuation, without surrounding whitespace.
    var text: String
    /// Lowercased, without accents or punctuation.
    var key: String
    var style = Style()
    var spaceAfter = true
    /// Line breaks in the script after this word.
    var breaksAfter = 0
    /// Relative time to read the word: its letters, plus a pause at punctuation.
    var weight: Double = 1
    /// True at the end of a sentence or clause; tap mode advances to these.
    var endsPhrase = false
}

/// A script split into words. Tap mode, reading speed and voice tracking all work from this.
struct ScriptWords: Equatable {
    struct StyleRun {
        /// Run length in UTF-16 units.
        var length: Int
        var style: ScriptWord.Style
    }

    let words: [ScriptWord]
    let totalWeight: Double
    let text: String
    /// Tells two scripts apart without comparing their text on every frame.
    let textHash: Int

    var count: Int { words.count }
    var isEmpty: Bool { words.isEmpty }

    /// Weight read per second at 1.0× speed, a natural speaking pace.
    var weightPerSecondAtNormalSpeed: Double {
        guard !words.isEmpty else { return 1 }
        return totalWeight / Double(words.count) * AppConstants.wordsPerSecond
    }

    /// Word layout goes left to right, so these scripts keep the plain scrolling text.
    var isRightToLeft: Bool {
        text.unicodeScalars.prefix(400).contains { (0x0590...0x08FF).contains($0.value) }
    }

    init(text: String, styleRuns: [StyleRun] = []) {
        self.text = text
        textHash = text.hashValue
        let ns = text as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            ranges.append(range)
        }

        var built: [ScriptWord] = []
        built.reserveCapacity(ranges.count)
        var leading = ranges.first.map {
            ns.substring(to: $0.location).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        var runIndex = 0
        var runEnd = styleRuns.first?.length ?? Int.max

        for (index, range) in ranges.enumerated() {
            let core = ns.substring(with: range)
            let isLast = index == ranges.count - 1
            let gapEnd = isLast ? ns.length : ranges[index + 1].location
            let gap = ns.substring(with: NSRange(location: range.upperBound, length: gapEnd - range.upperBound))
            let parts = Self.splitGap(gap)

            while range.location >= runEnd, runIndex + 1 < styleRuns.count {
                runIndex += 1
                runEnd += styleRuns[runIndex].length
            }

            let trailing = isLast ? parts.head + parts.tail : parts.head
            let endsSentence = trailing.contains { ".!?…。！？".contains($0) }
            let endsClause = trailing.contains { ",;:—–、，；：".contains($0) }
            var weight = Double(core.count) + 1
            if endsSentence { weight += 6 } else if endsClause { weight += 3 }
            weight += Double(min(parts.breaks, 2)) * 4

            built.append(ScriptWord(
                text: leading + core + trailing,
                key: Self.matchKey(core),
                style: styleRuns.isEmpty ? .init() : styleRuns[runIndex].style,
                spaceAfter: parts.hasSpace,
                breaksAfter: parts.breaks,
                weight: weight,
                endsPhrase: endsSentence || endsClause || parts.breaks > 0
            ))
            leading = isLast ? "" : parts.tail
        }
        words = built
        totalWeight = built.reduce(0) { $0 + $1.weight }
    }

    /// Splits the text between two words: everything up to the last whitespace stays with the
    /// word before, and what follows it (an opening quote, say) goes with the word after.
    private static func splitGap(_ gap: String) -> (head: String, tail: String, hasSpace: Bool, breaks: Int) {
        guard let lastSpace = gap.lastIndex(where: { $0.isWhitespace }) else {
            return (gap, "", false, 0)
        }
        let head = gap[..<lastSpace]
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // A dash on its own keeps its space from the word before.
        let spacedHead = gap.first?.isWhitespace == true && !head.isEmpty ? " " + head : head
        return (spacedHead, String(gap[gap.index(after: lastSpace)...]), true, gap.filter(\.isNewline).count)
    }

    static func matchKey(_ word: String) -> String {
        let folded = word.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// Normalizes recognized speech the same way as the script's words.
    static func spokenKeys(from segments: [String]) -> [String] {
        segments.flatMap { segment in
            ScriptWords(text: segment).words.map(\.key)
        }.filter { !$0.isEmpty }
    }

    /// First word of the next phrase, at least `minimumWords` ahead.
    func nextPhraseStart(after index: Int, minimumWords: Int = 3) -> Int {
        guard !words.isEmpty else { return 0 }
        var cursor = max(0, index)
        while cursor < words.count - 1 {
            if words[cursor].endsPhrase, cursor + 1 - index >= minimumWords { return cursor + 1 }
            cursor += 1
        }
        return words.count - 1
    }

    /// First word of the phrase before the one containing `index`.
    func previousPhraseStart(before index: Int, minimumWords: Int = 3) -> Int {
        guard !words.isEmpty else { return 0 }
        var cursor = min(index, words.count) - 2
        while cursor >= 0 {
            if words[cursor].endsPhrase, index - (cursor + 1) >= minimumWords { return cursor + 1 }
            cursor -= 1
        }
        return 0
    }
}

/// Finds where in the script the speaker is, from the latest recognized words.
/// Tolerates misheard, skipped and added words, and follows a speaker who jumps ahead or goes back.
struct WordAligner {
    private let keys: [String]
    /// Index of the last script word heard; -1 before the first.
    private(set) var position = -1

    private static let tailLength = 8
    private static let lookahead = 60
    private static let lookbehind = 40

    init(words: ScriptWords) {
        keys = words.words.map(\.key)
    }

    mutating func seek(to index: Int) {
        position = min(max(-1, index), keys.count - 1)
    }

    /// Feeds the latest recognized words, most recent last. Returns true when the position moved.
    @discardableResult
    mutating func update(spoken: [String]) -> Bool {
        let tail = Array(spoken.suffix(Self.tailLength))
        guard !tail.isEmpty, !keys.isEmpty else { return false }

        if let local = bestLocalMatch(tail: tail), accepts(end: local.end, score: local.score) {
            guard local.end != position else { return false }
            position = local.end
            return true
        }
        if let far = farMatch(tail: tail) {
            position = far
            return true
        }
        return false
    }

    // MARK: - Local search

    private func bestLocalMatch(tail: [String]) -> (end: Int, score: Double)? {
        let low = max(0, position - Self.lookbehind)
        let high = min(keys.count - 1, position + Self.lookahead)
        guard low <= high else { return nil }
        let expected = position + 1
        let lastHeard = tail.suffix(2)

        var best: (end: Int, score: Double, rank: Double)?
        for end in low...high where lastHeard.contains(where: { Self.matches($0, keys[end]) }) {
            let score = alignmentScore(tail: tail, endingAt: end)
            // Prefer staying close to where the speaker is expected to be.
            let rank = score - Double(abs(end - expected)) * 0.05
            if best == nil || rank > best!.rank {
                best = (end, score, rank)
            }
        }
        return best.map { ($0.end, $0.score) }
    }

    private func accepts(end: Int, score: Double) -> Bool {
        let jump = end - position
        switch jump {
        case 0: return true
        case 1...2: return score >= 0.4
        case 3...10: return score >= 2
        case 11...: return score >= 3
        default: return score >= 4
        }
    }

    /// Walks back from `end`, scoring how well the recent speech lines up with the script.
    private func alignmentScore(tail: [String], endingAt end: Int) -> Double {
        var heard = tail.count - 1
        var script = end
        var score = 0.0
        var gaps = 0
        while heard >= 0, script >= 0 {
            if Self.matches(tail[heard], keys[script]) {
                score += Self.weight(of: keys[script])
                heard -= 1
                script -= 1
                continue
            }
            gaps += 1
            if gaps > 3 { break }
            score -= 0.25
            if heard > 0, Self.matches(tail[heard - 1], keys[script]) {
                heard -= 1              // An added or misheard extra word.
            } else if script > 0, Self.matches(tail[heard], keys[script - 1]) {
                script -= 1             // A skipped script word.
            } else {
                heard -= 1
                script -= 1             // A misheard word.
            }
        }
        return score
    }

    // MARK: - Far search

    /// A speaker who skipped a long way: only an exact run of recent words counts.
    private func farMatch(tail: [String]) -> Int? {
        let run = Array(tail.suffix(4))
        guard run.count == 4, keys.count >= 4,
              run.reduce(0, { $0 + Self.weight(of: $1) }) >= 3 else { return nil }
        var closest: Int?
        for start in 0...(keys.count - 4) where keys[start] == run[0] {
            guard Array(keys[start..<(start + 4)]) == run else { continue }
            let end = start + 3
            if closest == nil || abs(end - position) < abs(closest! - position) {
                closest = end
            }
        }
        return closest
    }

    // MARK: - Word comparison

    /// Short common words say little about where the speaker is.
    private static func weight(of key: String) -> Double {
        switch key.count {
        case ...2: return 0.4
        case 3: return 0.6
        default: return 1
        }
    }

    private static func matches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let longest = max(a.count, b.count)
        let allowed = longest >= 8 ? 2 : (longest >= 4 ? 1 : 0)
        guard allowed > 0, abs(a.count - b.count) <= allowed, a.first == b.first else { return false }
        return editDistance(a, b, limit: allowed) <= allowed
    }

    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
