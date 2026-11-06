//
//  EditList.swift
//  yprompt
//

#if os(iOS)
import Foundation

/// A stretch of a source file placed on the recording's timeline.
nonisolated struct TimelineSegment: Equatable, Sendable {
    let pieceID: UUID
    let file: String
    let sourceStart: Double
    let sourceEnd: Double
    let timelineStart: Double

    var length: Double { sourceEnd - sourceStart }
    var timelineEnd: Double { timelineStart + length }
}

/// Where a piece sits on the timeline.
nonisolated struct PieceSpan: Equatable, Sendable {
    let pieceID: UUID
    let start: Double
    let end: Double

    var length: Double { end - start }
}

/// A recording laid out in time: each piece's kept parts, one after another.
/// With Remove Pauses on, a piece keeps only the stretches where something is said.
struct EditList: Equatable {
    let segments: [TimelineSegment]
    let spans: [PieceSpan]
    let length: Double

    /// Words further apart than this are separate runs when pauses are removed.
    private static let pauseGap = 0.6
    /// Room kept either side of a run, so words don't start or end abruptly.
    private static let runPadding = 0.12

    init(recording: Recording, analyses: [String: TakeAnalysis]) {
        var segments: [TimelineSegment] = []
        var spans: [PieceSpan] = []
        var cursor = 0.0
        for piece in recording.pieces {
            let start = cursor
            let kept = recording.removePauses
                ? Self.spokenRuns(of: piece, analysis: analyses[piece.file])
                : [piece.start...piece.end]
            for range in kept where range.upperBound - range.lowerBound > 0.04 {
                segments.append(TimelineSegment(pieceID: piece.id, file: piece.file, sourceStart: range.lowerBound,
                                                sourceEnd: range.upperBound, timelineStart: cursor))
                cursor += range.upperBound - range.lowerBound
            }
            spans.append(PieceSpan(pieceID: piece.id, start: start, end: cursor))
        }
        self.segments = segments
        self.spans = spans
        length = cursor
    }

    // MARK: Time

    /// A moment of a piece's source on the timeline; nil if that moment was cut.
    func timelineTime(piece: UUID, source: Double) -> Double? {
        segments.first { $0.pieceID == piece && $0.sourceStart - 0.001 <= source && source <= $0.sourceEnd + 0.001 }
            .map { $0.timelineStart + (source - $0.sourceStart) }
    }

    /// The piece and source moment shown at a time on the timeline.
    func location(at time: Double) -> (pieceID: UUID, source: Double)? {
        guard let segment = segments.first(where: { time < $0.timelineEnd }) ?? segments.last else { return nil }
        let offset = min(max(0, time - segment.timelineStart), segment.length)
        return (segment.pieceID, segment.sourceStart + offset)
    }

    func span(of piece: UUID) -> PieceSpan? {
        spans.first { $0.pieceID == piece }
    }

    // MARK: Captions

    /// Captions for the whole timeline. Each piece is lined up with the script on its own,
    /// since a pickup covers just part of it, and starts a new caption.
    func captionLines(for recording: Recording, analyses: [String: TakeAnalysis], script: ScriptWords) -> [CaptionLine] {
        var placed: [CaptionTrack.PlacedWord] = []
        for piece in recording.pieces {
            guard let words = analyses[piece.file]?.words else { continue }
            let inPiece = words.filter { (piece.start...piece.end).contains(($0.start + $0.end) / 2) }
            var isFirst = true
            for var word in CaptionTrack.placedWords(spoken: inPiece, script: script) {
                guard let start = timelineTime(piece: piece.id, source: max(word.word.start, piece.start)) else { continue }
                let end = timelineTime(piece: piece.id, source: min(word.word.end, piece.end)) ?? start + 0.2
                word.word.start = start
                word.word.end = max(start + 0.05, end)
                word.startsPiece = isFirst
                isFirst = false
                placed.append(word)
            }
        }
        return CaptionTrack.lines(from: placed)
    }

    /// The captions as plain text, a paragraph per piece.
    func transcript(of lines: [CaptionLine]) -> String {
        spans
            .map { span in
                lines.filter { $0.start >= span.start - 0.01 && $0.start < span.end }.map(\.text).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n") + "\n"
    }

    // MARK: Pickups

    /// Where reading should carry on after a piece: the word after the last one said in it,
    /// or the reading position when it stopped if no words line up with the script.
    static func pickupProgress(after piece: Piece, analysis: TakeAnalysis?, script: ScriptWords) -> Double {
        guard script.count > 0, let words = analysis?.words else { return piece.endProgress }
        let inPiece = words.filter { (piece.start...piece.end).contains(($0.start + $0.end) / 2) }
        guard let last = CaptionTrack.lastScriptWordIndex(spoken: inPiece, script: script) else { return piece.endProgress }
        return min(1, Double(last + 1) / Double(script.count))
    }

    // MARK: Pauses

    /// The parts of a piece where something is said, from the words, or from loudness when
    /// there are none. A piece with nothing found is kept whole rather than dropped.
    static func spokenRuns(of piece: Piece, analysis: TakeAnalysis?) -> [ClosedRange<Double>] {
        var runs: [ClosedRange<Double>] = []
        func add(_ range: ClosedRange<Double>) {
            if let last = runs.last, range.lowerBound - last.upperBound < pauseGap {
                runs[runs.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                runs.append(range)
            }
        }
        let words = (analysis?.words ?? []).filter { $0.end > piece.start && $0.start < piece.end }
        if !words.isEmpty {
            words.forEach { add($0.start...max($0.start, $0.end)) }
        } else if let envelope = analysis?.envelope, envelope.count > 10 {
            let threshold = envelope.sorted()[envelope.count / 10] + 12
            let step = TakeAnalysis.envelopeInterval
            for (index, level) in envelope.enumerated() where level > threshold {
                let time = Double(index) * step
                if time + step > piece.start && time < piece.end { add(time...(time + step)) }
            }
        }

        var padded: [ClosedRange<Double>] = []
        for run in runs {
            let low = max(piece.start, run.lowerBound - runPadding)
            let high = min(piece.end, run.upperBound + runPadding)
            guard high > low else { continue }
            if let last = padded.last, low <= last.upperBound {
                padded[padded.count - 1] = last.lowerBound...max(last.upperBound, high)
            } else {
                padded.append(low...high)
            }
        }
        return padded.isEmpty ? [piece.start...piece.end] : padded
    }
}
#endif
