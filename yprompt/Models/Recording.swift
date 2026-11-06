//
//  Recording.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import Foundation
import Observation

/// One stretch of a recording: part of a source file, which edits never change.
/// Split makes two pieces over the same file; trimming moves `start` and `end`.
nonisolated struct Piece: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    /// The source file's name in the recording's folder.
    var file: String
    /// The kept part of the source, in seconds.
    var start: Double
    var end: Double
    /// Reading position (0…1) when this piece's recording began and ended.
    var startProgress: Double
    var endProgress: Double
    /// Set once the ends have been cut to the first and last word. The trim handles can undo it.
    var trimmedToSpeech = false

    var length: Double { max(0, end - start) }
}

/// Everything recorded for one script in one go, plus pickups added later, with its edits.
/// Kept on this device only, as files: videos are too big for the iCloud-synced store.
nonisolated struct Recording: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case video, audio
    }

    var id = UUID()
    var scriptID: UUID?
    var title: String
    var kind: Kind
    var createdAt = Date()
    var modifiedAt = Date()
    var pieces: [Piece] = []
    var removePauses = false
    var captionStyle: CaptionStyle = .lyrics
    var captionPosition: CaptionPosition = .bottom
    /// Quarter turns clockwise, for takes that came out sideways.
    var quarterTurns = 0
    var savedAt: Date?

    var folder: URL { RecordingStore.folder(for: id) }
    func url(of piece: Piece) -> URL { folder.appendingPathComponent(piece.file) }

    /// Length before Remove Pauses.
    var length: Double { pieces.reduce(0) { $0 + $1.length } }
}

/// What the camera or microphone is about to record into.
struct RecordingTarget {
    var scriptID: UUID?
    var title: String
    /// Adds to this recording instead of starting a new one.
    var recordingID: UUID?
    /// Where the new piece goes; nil adds it at the end.
    var insertAt: Int?
}

/// Recording more into an existing recording: where the new piece goes, and where reading
/// starts so it carries on from the piece before.
struct Pickup: Hashable {
    let recordingID: UUID
    let insertAt: Int
    let progress: Double
    let title: String
    let kind: Recording.Kind
}

/// A recording to open in the editor, with the piece to select.
struct RecordingSelection: Identifiable, Equatable {
    let recordingID: UUID
    var pieceID: UUID?
    var id: UUID { recordingID }
}

/// A piece being recorded. Its info is written before recording starts, so a recording
/// interrupted by the app closing can still be found and added afterwards.
nonisolated struct PendingPiece: Codable, Sendable {
    var recordingID: UUID
    var insertAt: Int?
    var scriptID: UUID?
    var title: String
    var kind: Recording.Kind
    var file: String
    var startProgress: Double
    var createdAt = Date()

    var url: URL { RecordingStore.folder(for: recordingID).appendingPathComponent(file) }
    var infoURL: URL { url.appendingPathExtension("pending.json") }
}

// MARK: - Files

/// Reads and writes recordings in `Application Support/Recordings/<id>/`.
nonisolated enum RecordingStore {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var root = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Large, and saved to Photos when they matter; the tab says they aren't backed up.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return root
    }()

    static func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func infoURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("recording.json")
    }

    static func load(_ id: UUID) -> Recording? {
        guard let data = try? Data(contentsOf: infoURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(Recording.self, from: data)
    }

    static func save(_ recording: Recording) {
        try? FileManager.default.createDirectory(at: recording.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(recording) {
            try? data.write(to: infoURL(for: recording.id), options: .atomic)
        }
    }

    static func all() -> [Recording] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { UUID(uuidString: $0.lastPathComponent).flatMap(load) }
            .filter { !$0.pieces.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.folder)
    }

    /// Source files no piece uses any more, with their cached analysis.
    static func removeUnusedFiles(of recording: Recording) {
        let used = Set(recording.pieces.map(\.file))
        let files = (try? FileManager.default.contentsOfDirectory(at: recording.folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "mov" && !used.contains(file.lastPathComponent) {
            // A piece still being recorded has its pending info next to it.
            guard !FileManager.default.fileExists(atPath: file.appendingPathExtension("pending.json").path) else { continue }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: analysisURL(for: file))
        }
    }

    static func usedBytes() -> Int64 {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Analysis cache

    private static func analysisURL(for source: URL) -> URL {
        source.appendingPathExtension("analysis.json")
    }

    static func cachedAnalysis(for source: URL) -> TakeAnalysis? {
        guard let data = try? Data(contentsOf: analysisURL(for: source)),
              let analysis = try? JSONDecoder().decode(TakeAnalysis.self, from: data),
              analysis.speech == .recognized else { return nil }
        return analysis
    }

    static func cache(_ analysis: TakeAnalysis, for source: URL) {
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: analysisURL(for: source), options: .atomic)
        }
    }

    // MARK: Recording pieces

    static func beginPiece(_ target: RecordingTarget, kind: Recording.Kind, startProgress: Double) -> PendingPiece {
        let recordingID = target.recordingID ?? UUID()
        try? FileManager.default.createDirectory(at: folder(for: recordingID), withIntermediateDirectories: true)
        let pending = PendingPiece(recordingID: recordingID, insertAt: target.insertAt, scriptID: target.scriptID,
                                   title: target.title, kind: kind, file: UUID().uuidString + ".mov",
                                   startProgress: startProgress)
        if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: pending.infoURL, options: .atomic)
        }
        return pending
    }

    /// Adds a finished piece to its recording, creating the recording if it's new.
    /// Returns nil, and removes the file, when the recording can't be played.
    static func finishPiece(_ pending: PendingPiece, endProgress: Double) async -> (Recording, Piece)? {
        defer { try? FileManager.default.removeItem(at: pending.infoURL) }
        guard let duration = await playableDuration(of: pending.url) else {
            try? FileManager.default.removeItem(at: pending.url)
            if load(pending.recordingID) == nil { try? FileManager.default.removeItem(at: folder(for: pending.recordingID)) }
            return nil
        }
        let defaults = UserDefaults.standard
        var recording = load(pending.recordingID) ?? Recording(
            id: pending.recordingID, scriptID: pending.scriptID, title: pending.title, kind: pending.kind,
            createdAt: pending.createdAt,
            captionStyle: CaptionStyle(rawValue: defaults.string(forKey: ReadingPreferences.takeCaptionStyleKey) ?? "") ?? .lyrics,
            captionPosition: CaptionPosition(rawValue: defaults.string(forKey: ReadingPreferences.takeCaptionPositionKey) ?? "") ?? .bottom
        )
        let piece = Piece(file: pending.file, start: 0, end: duration,
                          startProgress: pending.startProgress, endProgress: endProgress)
        let index = min(max(0, pending.insertAt ?? recording.pieces.count), recording.pieces.count)
        recording.pieces.insert(piece, at: index)
        recording.modifiedAt = Date()
        save(recording)
        return (recording, piece)
    }

    /// Pieces left pending because the app closed while recording: added if they play,
    /// removed if not. Also clears folders that never got a recording.
    static func adoptLeftovers() async {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for info in files where info.lastPathComponent.hasSuffix(".pending.json") {
                guard let data = try? Data(contentsOf: info),
                      let pending = try? JSONDecoder().decode(PendingPiece.self, from: data),
                      !isRecent(pending.url) else { continue }
                _ = await finishPiece(pending, endProgress: pending.startProgress)
            }
            let hasRecording = FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.json").path)
            let hasPending = files.contains { $0.lastPathComponent.hasSuffix(".pending.json") && FileManager.default.fileExists(atPath: $0.path) }
            if !hasRecording && !hasPending && !isRecent(folder) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Takes kept by earlier 1.0.5 test builds become recordings of one piece.
    static func importOldTakes() async {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let takes = base.appendingPathComponent("Takes", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: takes, includingPropertiesForKeys: nil) else { return }
        struct OldTake: Decodable { var id: UUID; var scriptID: UUID?; var createdAt: Date; var startProgress: Double }
        for info in files where info.pathExtension == "json" {
            guard let data = try? Data(contentsOf: info),
                  let take = try? JSONDecoder().decode(OldTake.self, from: data) else { continue }
            let movie = takes.appendingPathComponent(take.id.uuidString).appendingPathExtension("mov")
            var pending = beginPiece(RecordingTarget(scriptID: take.scriptID, title: String(localized: "Take")),
                                     kind: .video, startProgress: take.startProgress)
            pending.createdAt = take.createdAt
            try? FileManager.default.removeItem(at: pending.url)
            guard (try? FileManager.default.moveItem(at: movie, to: pending.url)) != nil else {
                try? FileManager.default.removeItem(at: pending.infoURL)
                continue
            }
            _ = await finishPiece(pending, endProgress: take.startProgress)
        }
        try? FileManager.default.removeItem(at: takes)
    }

    private static func playableDuration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let (playable, duration) = try? await asset.load(.isPlayable, .duration),
              playable, duration.seconds > 0.3 else { return nil }
        return duration.seconds
    }

    /// Something modified in the last ten seconds may still be being written.
    private static func isRecent(_ url: URL) -> Bool {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified.map { Date().timeIntervalSince($0) < 10 } ?? false
    }
}

// MARK: - Library

/// The recordings shown in the tab and opened in the editor, kept in step with the files.
@Observable @MainActor
final class RecordingLibrary {
    static let shared = RecordingLibrary()

    private(set) var recordings: [Recording] = []
    private(set) var usedBytes: Int64 = 0
    @ObservationIgnored private var didLoad = false

    /// Picks up anything left from an interrupted recording, once per launch.
    func load() async {
        if !didLoad {
            didLoad = true
            await RecordingStore.importOldTakes()
            await RecordingStore.adoptLeftovers()
        }
        refresh()
    }

    func refresh() {
        recordings = RecordingStore.all()
        usedBytes = RecordingStore.usedBytes()
    }

    func recording(_ id: UUID) -> Recording? {
        recordings.first { $0.id == id } ?? RecordingStore.load(id)
    }

    func save(_ recording: Recording) {
        var recording = recording
        recording.modifiedAt = Date()
        RecordingStore.save(recording)
        RecordingStore.removeUnusedFiles(of: recording)
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
            usedBytes = RecordingStore.usedBytes()
        } else {
            refresh()
        }
    }

    func delete(_ recording: Recording) {
        RecordingStore.delete(recording)
        recordings.removeAll { $0.id == recording.id }
        usedBytes = RecordingStore.usedBytes()
    }
}
#endif
