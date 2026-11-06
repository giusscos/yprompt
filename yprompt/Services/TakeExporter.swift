//
//  TakeExporter.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import Photos

/// Turns a take into the clip the reader keeps: cut to the trim, with captions burned in.
enum TakeExporter {
    struct Captions: Equatable {
        var lines: [CaptionLine]
        var style: CaptionStyle
        var position: CaptionPosition
    }

    enum ExportError: LocalizedError {
        case noVideo
        case cannotExport
        case photosNotAllowed

        var errorDescription: String? {
            switch self {
            case .noVideo, .cannotExport: String(localized: "This take couldn't be saved.")
            case .photosNotAllowed: String(localized: "Allow yPrompt to add to Photos in Settings to save your takes.")
            }
        }
    }

    /// Folder for finished clips waiting to be saved or shared.
    static let rendersFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Renders", isDirectory: true)

    /// Writes the take cut to `range`, with captions when given, and returns the new file.
    static func render(
        take: Take,
        range: ClosedRange<Double>,
        captions: Captions?,
        fileName: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let folder = rendersFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(fileName).appendingPathExtension("mov")

        let asset = AVURLAsset(url: take.url)
        let timeRange = CMTimeRange(start: time(range.lowerBound), end: time(range.upperBound))
        let session: AVAssetExportSession
        if let captions, captions.style != .off, !captions.lines.isEmpty {
            session = try await captionedSession(asset: asset, captions: captions)
        } else {
            // Only cutting: the video is copied as it is, which is quick and loses nothing.
            guard let passthrough = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw ExportError.cannotExport
            }
            session = passthrough
        }
        session.timeRange = timeRange
        try await run(session, to: output, progress: progress)
        return output
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

    // MARK: - Captions

    private static func captionedSession(asset: AVURLAsset, captions: Captions) async throws -> AVAssetExportSession {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let formats = try await video.load(.formatDescriptions)
        let isHEVC = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
        let preset = isHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw ExportError.cannotExport }
        session.videoComposition = try await CaptionComposition.make(
            for: asset, captions: captions, size: try await uprightSize(of: asset))
        return session
    }

    /// The camera stores how the phone was held as a transform; this is the picture as it's seen.
    static func uprightSize(of asset: AVAsset) async throws -> CGSize {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let (size, transform) = try await video.load(.naturalSize, .preferredTransform)
        let upright = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(upright.width).rounded(), height: abs(upright.height).rounded())
    }

    // MARK: - Running the export

    private static func run(
        _ session: AVAssetExportSession, to url: URL, progress: @escaping (Double) -> Void
    ) async throws {
        if #available(iOS 18.0, *) {
            let watcher = Task {
                for await state in session.states(updateInterval: 0.2) {
                    if case .exporting(let exportProgress) = state { progress(exportProgress.fractionCompleted) }
                }
            }
            defer { watcher.cancel() }
            try await session.export(to: url, as: .mov)
        } else {
            session.outputURL = url
            session.outputFileType = .mov
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

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
#endif
