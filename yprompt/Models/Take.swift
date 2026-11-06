//
//  Take.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import Foundation

/// A finished recording waiting for the reader to save or retake it. It stays in the app's own
/// folder, not in Photos, until they decide, so a take survives the app closing.
nonisolated struct Take: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var scriptID: UUID?
    var createdAt: Date
    /// Reading position (0…1) when recording began; Retake goes back to it.
    var startProgress: Double

    var url: URL { TakeStore.folder.appendingPathComponent(id.uuidString).appendingPathExtension("mov") }
    fileprivate var infoURL: URL { TakeStore.folder.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
}

/// Keeps takes on disk until they're saved to Photos or thrown away.
nonisolated enum TakeStore {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = base.appendingPathComponent("Takes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Videos are large, and a take only lives until the reader decides what to do with it.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }()

    /// A take to record into. Its info is written now, so it can be found again if the app closes.
    static func newTake(scriptID: UUID?, startProgress: Double) -> Take {
        let take = Take(id: UUID(), scriptID: scriptID, createdAt: Date(), startProgress: startProgress)
        if let data = try? JSONEncoder().encode(take) {
            try? data.write(to: take.infoURL, options: .atomic)
        }
        return take
    }

    /// Takes for this script that were never saved or thrown away, oldest first.
    /// A recording that never finished can't be played, so those are removed instead.
    static func unsavedTakes(for scriptID: UUID) async -> [Take] {
        let takes = allTakes().filter { $0.scriptID == scriptID }
        var playable: [Take] = []
        for take in takes {
            if await isPlayable(take) {
                playable.append(take)
            } else if !isBeingWritten(take) {
                discard(take)
            }
        }
        return playable
    }

    /// A recording that was just stopped may still be finishing its file.
    private static func isBeingWritten(_ take: Take) -> Bool {
        let modified = (try? take.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified.map { Date().timeIntervalSince($0) < 10 } ?? false
    }

    static func discard(_ take: Take) {
        try? FileManager.default.removeItem(at: take.url)
        try? FileManager.default.removeItem(at: take.infoURL)
    }

    private static func allTakes() -> [Take] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Take.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private static func isPlayable(_ take: Take) async -> Bool {
        let asset = AVURLAsset(url: take.url)
        guard let (playable, duration) = try? await asset.load(.isPlayable, .duration) else { return false }
        return playable && duration.seconds > 0.5
    }
}
#endif
