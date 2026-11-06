//
//  CaptionTrack.swift
//  yprompt
//

#if os(iOS)
import Foundation

nonisolated struct CaptionWord: Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// One caption on screen: a few words, shown from the first word until the next caption.
nonisolated struct CaptionLine: Hashable, Sendable {
    var words: [CaptionWord]
    var start: Double
    var end: Double

    var text: String { words.map(\.text).joined(separator: " ") }
}

/// Turns the words heard in a take into captions spelled like the script.
enum CaptionTrack {
    private static let maxWordsPerLine = 5
    private static let maxCharactersPerLine = 32
    /// A phrase may stretch a caption this far rather than leave a word or two on their own.
    private static let stretchedWordsPerLine = 7
    private static let stretchedCharactersPerLine = 42
    /// A pause this long starts a new caption.
    private static let pauseBreak = 0.7
    /// A caption stays up at most this long after its last word.
    private static let hold = 1.0

    static func lines(spoken: [SpokenWord], script: ScriptWords) -> [CaptionLine] {
        group(captionWords(spoken: spoken, script: script))
    }

    /// Subtitles for the clip cut to `range`, with times counted from its start.
    static func srt(_ lines: [CaptionLine], in range: ClosedRange<Double>) -> String {
        var output = ""
        var number = 0
        for line in lines where line.end > range.lowerBound && line.start < range.upperBound {
            number += 1
            let start = max(line.start, range.lowerBound) - range.lowerBound
            let end = min(line.end, range.upperBound) - range.lowerBound
            output += "\(number)\n\(timestamp(start)) --> \(timestamp(end))\n\(line.text)\n\n"
        }
        return output
    }

    // MARK: - Matching speech to the script

    private struct Placed {
        var word: CaptionWord
        var endsPhrase: Bool
        /// False for words the speaker added; a caption doesn't mix the two.
        var isScript: Bool
    }

    /// Words that line up with the script get its spelling and punctuation. A short misheard
    /// stretch between two matches becomes the script's words over the same time. Ad-libs keep
    /// what recognition heard, and script words that weren't said are left out.
    private static func captionWords(spoken: [SpokenWord], script: ScriptWords) -> [Placed] {
        let aligned = align(spoken: spoken.map { ScriptWords.matchKey($0.text) }, script: script.words.map(\.key))
        var placed: [Placed] = []
        var index = 0
        while index < spoken.count {
            if let pair = aligned[index], pair.isMatch {
                let word = script.words[pair.scriptIndex]
                placed.append(Placed(word: CaptionWord(text: word.text, start: spoken[index].start, end: spoken[index].end),
                                     endsPhrase: word.endsPhrase, isScript: true))
                index += 1
                continue
            }
            let runStart = index
            while index < spoken.count, aligned[index]?.isMatch != true { index += 1 }
            let run = spoken[runStart..<index]
            let before = runStart > 0 ? aligned[runStart - 1]?.scriptIndex : nil
            let after = index < spoken.count ? aligned[index]?.scriptIndex : nil
            if let before, let after, (1...3).contains(after - before - 1), run.count <= 3,
               let first = run.first, let last = run.last {
                placed += spread(script.words[(before + 1)..<after], from: first.start, to: last.end)
            } else {
                placed += run.map { Placed(word: CaptionWord(text: $0.text, start: $0.start, end: $0.end),
                                           endsPhrase: false, isScript: false) }
            }
        }
        return placed
    }

    /// Script words placed over a stretch of time, each taking a share as long as its text.
    private static func spread(_ words: ArraySlice<ScriptWord>, from start: Double, to end: Double) -> [Placed] {
        let total = Double(words.reduce(0) { $0 + max(1, $1.text.count) })
        var time = start
        return words.map { word in
            let length = (end - start) * Double(max(1, word.text.count)) / total
            defer { time += length }
            return Placed(word: CaptionWord(text: word.text, start: time, end: time + length),
                          endsPhrase: word.endsPhrase, isScript: true)
        }
    }

    private struct Pair {
        var scriptIndex: Int
        var isMatch: Bool
    }

    /// Global alignment of the speech against the script, where skipping the start or end of
    /// the script costs nothing: a take often covers only part of it.
    private static func align(spoken: [String], script: [String]) -> [Pair?] {
        let m = spoken.count, n = script.count
        var result = [Pair?](repeating: nil, count: m)
        // Very long takes of very long scripts would need too much memory; captions keep what was heard.
        guard m > 0, n > 0, m * n <= 6_000_000 else { return result }

        let columns = m + 1
        var score = [Int32](repeating: 0, count: (n + 1) * columns)
        // 0: diagonal (match or substitution), 1: skip a script word, 2: extra spoken word.
        var move = [UInt8](repeating: 0, count: (n + 1) * columns)
        for j in 1...m {
            score[j] = -Int32(j)
            move[j] = 2
        }
        for i in 1...n {
            let row = i * columns, previousRow = (i - 1) * columns
            move[row] = 1
            for j in 1...m {
                let isMatch = WordAligner.matches(spoken[j - 1], script[i - 1])
                let diagonal = score[previousRow + j - 1] + (isMatch ? 2 : -1)
                let skipScript = score[previousRow + j] - 1
                let extraSpoken = score[row + j - 1] - 1
                if diagonal >= skipScript && diagonal >= extraSpoken {
                    score[row + j] = diagonal
                    move[row + j] = 0
                } else if skipScript >= extraSpoken {
                    score[row + j] = skipScript
                    move[row + j] = 1
                } else {
                    score[row + j] = extraSpoken
                    move[row + j] = 2
                }
            }
        }

        var i = 0
        for candidate in 0...n where score[candidate * columns + m] > score[i * columns + m] { i = candidate }
        var j = m
        while j > 0 {
            guard i > 0 else { break }
            switch move[i * columns + j] {
            case 0:
                result[j - 1] = Pair(scriptIndex: i - 1, isMatch: WordAligner.matches(spoken[j - 1], script[i - 1]))
                i -= 1
                j -= 1
            case 1:
                i -= 1
            default:
                j -= 1
            }
        }
        return result
    }

    // MARK: - Lines

    private static func group(_ words: [Placed]) -> [CaptionLine] {
        var lines: [CaptionLine] = []
        var current: [CaptionWord] = []

        func close() {
            guard var last = current.last, let first = current.first else { return }
            // Captions read better without a full stop or comma at the end.
            while let character = last.text.last, ",.;:".contains(character), last.text.count > 1 {
                last.text.removeLast()
            }
            current[current.count - 1] = last
            lines.append(CaptionLine(words: current, start: first.start, end: last.end))
            current = []
        }

        // How many words are left in each word's phrase, counting itself.
        var leftInPhrase = [Int](repeating: 1, count: words.count)
        for index in words.indices.reversed() where index + 1 < words.count && !words[index].endsPhrase {
            leftInPhrase[index] = leftInPhrase[index + 1] + 1
        }

        var currentIsScript = true
        for (index, placed) in words.enumerated() {
            if let last = current.last {
                let characters = current.reduce(0) { $0 + $1.text.count + 1 } + placed.word.text.count
                let phraseNearlyDone = placed.isScript && leftInPhrase[index] <= 2
                let full = phraseNearlyDone
                    ? current.count >= stretchedWordsPerLine || characters > stretchedCharactersPerLine
                    : current.count >= maxWordsPerLine || characters > maxCharactersPerLine
                if full || placed.word.start - last.end > pauseBreak || placed.isScript != currentIsScript {
                    close()
                }
            }
            currentIsScript = placed.isScript
            current.append(placed.word)
            if placed.endsPhrase { close() }
        }
        close()

        for index in lines.indices {
            let nextStart = index + 1 < lines.count ? lines[index + 1].start : .infinity
            let lastEnd = lines[index].words.last?.end ?? lines[index].start
            var end = min(nextStart, lastEnd + hold)
            if end < lines[index].start + 0.3 { end = min(lines[index].start + 0.3, nextStart) }
            lines[index].end = max(end, lines[index].start + 0.05)
        }
        return lines
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d",
                      milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
#endif
