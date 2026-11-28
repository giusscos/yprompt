//
//  DeliveryReport.swift
//  yprompt
//

#if os(iOS) || os(macOS)
import Foundation

/// How a recording was spoken: its pace, filler words, long pauses, and how closely it kept to
/// the script. Worked out from the words heard in each take, the same ones the captions use.
/// Clips added from Photos or Files aren't counted: they aren't the reader's delivery.
struct DeliveryReport {
    /// A moment in one take, to list and to jump to.
    struct Moment: Identifiable, Hashable {
        let id = UUID()
        let pieceID: UUID
        /// Where it happens in the piece's source file.
        let source: Double
        /// The filler word, or the script words that were skipped.
        var text = ""
        /// How long a pause lasted.
        var seconds: Double = 0
    }

    /// The pace over a stretch of about ten seconds.
    struct PaceSample: Identifiable, Hashable {
        let id: Int
        let pieceID: UUID
        let source: Double
        let wordsPerMinute: Double
    }

    enum Pace {
        case slow, good, fast
    }

    /// Around 140 words a minute is easy to follow on video; this is the band called "good".
    static let comfortablePace: ClosedRange<Double> = 120...170
    /// A silence at least this long counts as a long pause.
    static let longPause = 1.5
    private static let sampleSeconds = 10.0

    private(set) var wordCount = 0
    /// Time spent speaking: from the first word to the last of each take, without long pauses.
    private(set) var speakingSeconds: Double = 0
    private(set) var paceSamples: [PaceSample] = []
    private(set) var fillers: [Moment] = []
    private(set) var pauses: [Moment] = []
    /// Words said that aren't in the script, fillers aside.
    private(set) var addedWords = 0
    /// Share of the script's words said, between the first and last script words heard.
    private(set) var scriptCoverage: Double?
    /// Three or more script words in a row that weren't said, after the first heard.
    private(set) var skipped: [Moment] = []

    /// Nil when too little was said to tell.
    var wordsPerMinute: Double? {
        guard wordCount >= 10, speakingSeconds >= 5 else { return nil }
        return Double(wordCount) / speakingSeconds * 60
    }

    var pace: Pace? {
        guard let wordsPerMinute else { return nil }
        if wordsPerMinute < Self.comfortablePace.lowerBound { return .slow }
        return wordsPerMinute > Self.comfortablePace.upperBound ? .fast : .good
    }

    var fastest: PaceSample? {
        guard paceSamples.count >= 3, let wordsPerMinute,
              let top = paceSamples.max(by: { $0.wordsPerMinute < $1.wordsPerMinute }),
              top.wordsPerMinute > max(wordsPerMinute * 1.15, Self.comfortablePace.upperBound) else { return nil }
        return top
    }

    var isEmpty: Bool { wordCount == 0 }

    init(recording: Recording, analyses: [String: TakeAnalysis], script: ScriptWords) {
        // The same language the words were recognized in.
        let fillerWords = Self.fillerWords(language: script.count > 0 ? SpeechWordTracker.language(ofScript: script.text) : nil)
        // Where each script word was first said, to place the passages that were skipped.
        var saidAt: [Int: (pieceID: UUID, source: Double)] = [:]
        var sampleID = 0

        for piece in recording.pieces where !piece.isImported {
            guard let words = analyses[piece.file]?.words else { continue }
            let spoken = words.filter { (piece.start...piece.end).contains(($0.start + $0.end) / 2) }
            guard let first = spoken.first else { continue }
            let matches = script.count > 0
                ? CaptionTrack.scriptMatches(spoken: spoken, script: script)
                : Array(repeating: nil, count: spoken.count)
            wordCount += spoken.count

            // Fillers and added words: only words that aren't the script's, so a scripted "like" is fine.
            var index = 0
            while index < spoken.count {
                if let scriptIndex = matches[index] {
                    if saidAt[scriptIndex] == nil { saidAt[scriptIndex] = (piece.id, spoken[index].end) }
                    index += 1
                    continue
                }
                let key = ScriptWords.matchKey(spoken[index].text)
                if index + 1 < spoken.count, matches[index + 1] == nil,
                   fillerWords.contains(key + " " + ScriptWords.matchKey(spoken[index + 1].text)) {
                    fillers.append(Moment(pieceID: piece.id, source: spoken[index].start,
                                          text: (spoken[index].text + " " + spoken[index + 1].text).lowercased()))
                    index += 2
                } else if fillerWords.contains(key) {
                    fillers.append(Moment(pieceID: piece.id, source: spoken[index].start, text: spoken[index].text.lowercased()))
                    index += 1
                } else {
                    if !key.isEmpty { addedWords += 1 }
                    index += 1
                }
            }

            // Long pauses, and the time spent speaking without them.
            var runStart = first.start
            var lastEnd = first.end
            for word in spoken.dropFirst() {
                let gap = word.start - lastEnd
                if gap >= Self.longPause {
                    pauses.append(Moment(pieceID: piece.id, source: lastEnd, seconds: gap))
                    speakingSeconds += lastEnd - runStart
                    runStart = word.start
                }
                lastEnd = max(lastEnd, word.end)
            }
            speakingSeconds += lastEnd - runStart

            // The pace over stretches of about ten seconds.
            var sampleStart = 0
            while sampleStart < spoken.count {
                let begin = spoken[sampleStart].start
                var sampleEnd = sampleStart
                while sampleEnd + 1 < spoken.count, spoken[sampleEnd + 1].start < begin + Self.sampleSeconds {
                    sampleEnd += 1
                }
                let count = sampleEnd - sampleStart + 1
                let seconds = spoken[sampleEnd].end - begin
                if count >= 4, seconds >= 3 {
                    paceSamples.append(PaceSample(id: sampleID, pieceID: piece.id, source: begin,
                                                  wordsPerMinute: Double(count) / seconds * 60))
                    sampleID += 1
                }
                sampleStart = sampleEnd + 1
            }
        }

        // The script between the first and last words heard: what share was said, and the
        // passages left out. A take often covers only part of the script, so the rest isn't counted.
        guard saidAt.count >= 5, let low = saidAt.keys.min(), let high = saidAt.keys.max() else { return }
        scriptCoverage = Double(saidAt.count) / Double(high - low + 1)
        var scriptIndex = low
        while scriptIndex <= high {
            guard saidAt[scriptIndex] == nil else {
                scriptIndex += 1
                continue
            }
            let runStart = scriptIndex
            while scriptIndex <= high, saidAt[scriptIndex] == nil { scriptIndex += 1 }
            let run = script.words[runStart..<scriptIndex]
            guard run.count >= 3, let before = saidAt[runStart - 1] else { continue }
            let text = run.prefix(10).map(\.text).joined(separator: " ") + (run.count > 10 ? "…" : "")
            skipped.append(Moment(pieceID: before.pieceID, source: before.source, text: text))
        }
    }

    // MARK: Filler words

    /// Sounds of hesitation in any language, plus the usual fillers of the script's language.
    /// Recognition leaves some "um"s out, so these counts are a floor.
    private static func fillerWords(language: String?) -> Set<String> {
        var words: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "eh", "ehm", "ah", "hmm", "mm", "mhm",
                                  "äh", "ähm", "euh", "eeh"]
        let local: [String] = switch language {
        case "en": ["like", "basically", "actually", "literally", "so", "well", "okay", "right",
                    "you know", "i mean", "kind of", "sort of"]
        case "it": ["tipo", "cioè", "allora", "praticamente", "insomma", "diciamo", "ecco", "quindi"]
        case "es": ["bueno", "pues", "este", "tipo", "básicamente", "vale", "o sea"]
        case "fr": ["genre", "bref", "voilà", "ben", "bah", "quoi", "du coup", "en fait", "tu vois"]
        case "de": ["also", "halt", "quasi", "sozusagen", "eigentlich", "irgendwie", "ich meine"]
        case "pt": ["tipo", "então", "né", "assim", "basicamente", "sei lá"]
        case "nl": ["eigenlijk", "gewoon", "dus", "nou", "zeg maar"]
        default: []
        }
        for word in local {
            words.insert(word.split(separator: " ").map { ScriptWords.matchKey(String($0)) }.joined(separator: " "))
        }
        return Set(words.map { $0.split(separator: " ").map { ScriptWords.matchKey(String($0)) }.joined(separator: " ") })
    }
}
#endif
