//
//  RecordingExporter.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import Photos

/// Turns a recording into the file people keep: a video, or for audio an .m4a.
enum RecordingExporter {
    enum ExportError: LocalizedError {
        case nothingToSave
        case cannotExport
        case photosNotAllowed

        var errorDescription: String? {
            switch self {
            case .nothingToSave, .cannotExport: String(localized: "This recording couldn't be saved.")
            case .photosNotAllowed: String(localized: "Allow yPrompt to add to Photos in Settings to save your recordings.")
            }
        }
    }

    /// Finished files waiting to be saved or shared; cleared when the editor closes.
    static let rendersFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Renders", isDirectory: true)

    static func render(
        _ recording: Recording,
        editList: EditList,
        composed: ComposedRecording,
        captions: CaptionRenderer?,
        mark: Watermark?,
        fileName: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard !editList.segments.isEmpty else { throw ExportError.nothingToSave }
        let folder = rendersFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let isAudio = recording.kind == .audio || !composed.isVideo
        let output = folder.appendingPathComponent(fileName).appendingPathExtension(isAudio ? "m4a" : "mov")

        let session: AVAssetExportSession
        let drawsOnTop = captions != nil || mark != nil
        if isAudio {
            guard let audio = AVAssetExportSession(asset: composed.composition, presetName: AVAssetExportPresetAppleM4A) else {
                throw ExportError.cannotExport
            }
            session = audio
        } else if editList.segments.count == 1, !drawsOnTop {
            // One stretch and nothing drawn on top: copy the video as it is, quick and lossless.
            session = try await copySession(recording, segment: editList.segments[0])
        } else {
            let preset = composed.isHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
            guard let video = AVAssetExportSession(asset: composed.composition, presetName: preset) else {
                throw ExportError.cannotExport
            }
            video.videoComposition = composed.exportComposition(captions: captions, mark: mark)
            session = video
        }
        try await run(session, to: output, as: isAudio ? .m4a : .mov, progress: progress)
        return output
    }

    /// One stretch copied without re-encoding. A rotation only changes the orientation tag.
    private static func copySession(_ recording: Recording, segment: TimelineSegment) async throws -> AVAssetExportSession {
        let asset = AVURLAsset(url: recording.folder.appendingPathComponent(segment.file))
        let range = CMTimeRange(start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                                end: CMTime(seconds: segment.sourceEnd, preferredTimescale: 600))
        let turns = ((recording.quarterTurns % 4) + 4) % 4
        guard turns != 0 else {
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw ExportError.cannotExport
            }
            session.timeRange = range
            return session
        }
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.cannotExport }
        let (size, transform) = try await sourceVideo.load(.naturalSize, .preferredTransform)
        let upright = CGRect(origin: .zero, size: size).applying(transform)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.cannotExport
        }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = transform.concatenating(RecordingComposer.clockwise(
            quarterTurns: turns, size: CGSize(width: abs(upright.width), height: abs(upright.height))))
        for sourceAudio in try await asset.loadTracks(withMediaType: .audio) {
            let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try audio?.insertTimeRange(range, of: sourceAudio, at: .zero)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.cannotExport
        }
        return session
    }

    /// Subtitles and a plain-text transcript next to a saved file, for sharing.
    static func writeTextFiles(next url: URL, lines: [CaptionLine], editList: EditList) -> [URL] {
        guard !lines.isEmpty else { return [] }
        let srt = url.deletingPathExtension().appendingPathExtension("srt")
        let txt = url.deletingPathExtension().appendingPathExtension("txt")
        var written: [URL] = []
        if (try? CaptionTrack.srt(lines, in: 0...max(editList.length, 0.1)).write(to: srt, atomically: true, encoding: .utf8)) != nil {
            written.append(srt)
        }
        if (try? editList.transcript(of: lines).write(to: txt, atomically: true, encoding: .utf8)) != nil {
            written.append(txt)
        }
        return written
    }

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.photosNotAllowed }
        try await PHPhotoLibrary.shared().performChanges(changes(addingVideoAt: url))
    }

    /// Photos runs the change on its own queue, so this closure must not inherit the main actor.
    nonisolated private static func changes(addingVideoAt url: URL) -> @Sendable () -> Void {
        { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
    }

    private static func run(
        _ session: AVAssetExportSession, to url: URL, as type: AVFileType, progress: @escaping (Double) -> Void
    ) async throws {
        if #available(iOS 18.0, *) {
            // Polled rather than read from `states(updateInterval:)`, whose iterator traps when an
            // export finishes before it takes its first look, as short audio exports do.
            let watcher = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { watcher.cancel() }
            try await session.export(to: url, as: type)
        } else {
            session.outputURL = url
            session.outputFileType = type
            let watcher = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { watcher.cancel() }
            await withTaskCancellationHandler {
                await session.export()
            } onCancel: {
                session.cancelExport()
            }
            if session.status == .cancelled { throw CancellationError() }
            if let error = session.error { throw error }
        }
    }
}
#endif
