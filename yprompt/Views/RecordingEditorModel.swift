//
//  RecordingEditorModel.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.giusscos.yprompt", category: "Editor")

/// Everything the editor shows and changes. Each edit is saved straight away, so closing
/// the editor never loses work.
@Observable @MainActor
final class RecordingEditorModel {
    enum Purpose: Equatable {
        case save, share
    }

    enum RenderState: Equatable {
        case idle
        case rendering(Purpose, progress: Double)
        case saved
        case failed(String)
    }

    struct ShareItems: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    private(set) var recording: Recording
    /// The script words the captions are spelled from; empty when the script was deleted.
    let script: ScriptWords
    let player = AVPlayer()

    private(set) var analyses: [String: TakeAnalysis] = [:]
    private(set) var isAnalyzing = false
    private(set) var editList: EditList
    private(set) var captionLines: [CaptionLine] = []
    private(set) var captionRenderer: CaptionRenderer?
    private(set) var mark: Watermark?
    /// The video as shown and saved, in pixels; zero for audio.
    private(set) var renderSize: CGSize = .zero
    private(set) var hasItem = false
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var thumbnails: [String: CGImage] = [:]
    private(set) var renderState: RenderState = .idle
    private(set) var canUndo = false
    /// Preview speed only; the saved recording always plays at normal speed.
    private(set) var playbackRate: Float = 1
    static let playbackRates: [Float] = [0.5, 1, 1.25, 1.5, 2]
    var selectedPieceID: UUID?
    var shareItems: ShareItems?
    /// Free users' videos carry the mark; Pro removes it.
    var showsMark = true {
        didSet { if showsMark != oldValue { refreshOverlays() } }
    }

    @ObservationIgnored private let fileName: String
    @ObservationIgnored private var composed: ComposedRecording?
    @ObservationIgnored private var undoSnapshot: Recording?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var lastRender: URL?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var sourceDurations: [String: Double] = [:]
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// What the player is showing: pieces, cuts and rotation. Edits that leave it the same
    /// (a split, a caption style) don't rebuild the player, so the preview never blinks.
    @ObservationIgnored private var composedSignature: [String]?
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: Double?

    init(recording: Recording, script: ScriptWords, selectedPieceID: UUID?) {
        self.recording = recording
        self.script = script
        self.selectedPieceID = selectedPieceID
        editList = EditList(recording: recording, analyses: [:])
        let cleaned = recording.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fileName = cleaned.isEmpty ? "yPrompt" : String(cleaned.prefix(60))
    }

    // MARK: State

    var isVideo: Bool { recording.kind == .video }

    var length: Double { editList.length }

    var selectedIndex: Int? {
        selectedPieceID.flatMap { id in recording.pieces.firstIndex { $0.id == id } }
    }

    var isRendering: Bool {
        if case .rendering = renderState { return true }
        return false
    }

    /// Recognition result for the captions: nil while still listening.
    var speechStatus: TakeAnalysis.Speech? {
        let files = Set(recording.pieces.map(\.file))
        let done = files.compactMap { analyses[$0] }
        guard done.count == files.count else { return nil }
        if done.contains(where: { $0.speech == .recognized }) { return .recognized }
        return done.contains(where: { $0.speech == .notAllowed }) ? .notAllowed : .unavailable
    }

    /// The caption line under the playhead, for audio recordings.
    var currentLine: CaptionLine? {
        captionLines.first { $0.start <= currentTime && currentTime < $0.end }
    }

    func thumbnail(for piece: Piece) -> CGImage? {
        thumbnails[thumbnailKey(piece)]
    }

    // MARK: Loading

    func load() async {
        guard !hasItem, timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player.timeControlStatus != .paused
            }
        }
        for file in Set(recording.pieces.map(\.file)) {
            if let cached = RecordingStore.cachedAnalysis(for: recording.folder.appendingPathComponent(file)) {
                analyses[file] = cached
            }
        }
        await rebuild(keepTime: false)
        player.play()
        analyzeMissing()
        #if DEBUG
        if analysisTask == nil { holdForScreenshot() }
        #endif
    }

    #if DEBUG
    /// For App Store screenshots: `-ypShotEditorTime 4.2` pauses on that moment once the
    /// captions are ready.
    private func holdForScreenshot() {
        let time = UserDefaults.standard.double(forKey: "ypShotEditorTime")
        guard time > 0 else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            player.pause()
            isPlaying = false
            seek(to: time)
        }
    }
    #endif

    /// Listens to each source that hasn't been transcribed yet, one at a time.
    private func analyzeMissing() {
        guard analysisTask == nil else { return }
        analysisTask = Task {
            defer {
                analysisTask = nil
                isAnalyzing = false
                #if DEBUG
                holdForScreenshot()
                #endif
            }
            while let file = recording.pieces.map(\.file).first(where: { analyses[$0] == nil }) {
                isAnalyzing = true
                let url = recording.folder.appendingPathComponent(file)
                let analysis = await TakeTranscriber.analyze(url: url, script: script)
                guard !Task.isCancelled else { return }
                // Only a finished transcript is kept: a failure (no network, permission not yet
                // given) is tried again the next time the editor opens.
                if analysis.speech == .recognized { RecordingStore.cache(analysis, for: url) }
                analyses[file] = analysis
                trimToSpeech(file: file, analysis: analysis)
                await rebuild(keepTime: true)
            }
        }
    }

    /// New pieces lose the silence before the first word and after the last, once.
    private func trimToSpeech(file: String, analysis: TakeAnalysis) {
        var changed = false
        for index in recording.pieces.indices where recording.pieces[index].file == file && !recording.pieces[index].trimmedToSpeech {
            let piece = recording.pieces[index]
            recording.pieces[index].trimmedToSpeech = true
            changed = true
            // Only a piece still covering its whole recording; a split one was already chosen by hand.
            guard piece.start < 0.05, let range = analysis.trimRange(duration: piece.end) else { continue }
            recording.pieces[index].start = range.lowerBound
            recording.pieces[index].end = range.upperBound
        }
        if changed { RecordingLibrary.shared.save(recording) }
    }

    // MARK: Building the preview

    private func rebuild(keepTime: Bool) async {
        rebuildTask?.cancel()
        let time = keepTime ? currentTime : 0
        let wasPlaying = keepTime ? isPlaying : true
        editList = EditList(recording: recording, analyses: analyses)
        captionLines = editList.captionLines(for: recording, analyses: analyses, script: script)
        let signature = Self.signature(of: recording, editList: editList)
        if composed != nil, signature == composedSignature {
            refreshOverlays()
            return
        }
        let recording = recording
        let editList = editList
        let task = Task { [weak self] in
            let composed: ComposedRecording
            do {
                composed = try await RecordingComposer.compose(recording, editList: editList)
            } catch {
                log.error("Couldn't put the recording together: \(String(describing: error), privacy: .public)")
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.composed = composed
            composedSignature = signature
            renderSize = composed.isVideo ? composed.renderSize : .zero
            refreshOverlays()
            let item = AVPlayerItem(asset: composed.composition)
            item.videoComposition = composed.previewComposition()
            watchForFailure(of: item, composition: composed.composition)
            loopAtEnd(of: item)
            player.replaceCurrentItem(with: item)
            hasItem = true
            let target = min(time, max(0, editList.length - 0.05))
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = target
            player.defaultRate = playbackRate
            if wasPlaying && !isRendering && shareItems == nil { player.play() }
            await loadThumbnails()
        }
        rebuildTask = task
        await task.value
    }

    /// The stretches of source on the timeline, joined where one carries straight on from
    /// the next, plus the rotation.
    private static func signature(of recording: Recording, editList: EditList) -> [String] {
        var joined: [(file: String, start: Double, end: Double)] = []
        for segment in editList.segments {
            if let last = joined.last, last.file == segment.file, abs(last.end - segment.sourceStart) < 0.001 {
                joined[joined.count - 1].end = segment.sourceEnd
            } else {
                joined.append((segment.file, segment.sourceStart, segment.sourceEnd))
            }
        }
        return ["\(recording.kind.rawValue) \(recording.quarterTurns % 4)"]
            + joined.map { String(format: "%@ %.3f %.3f", $0.file, $0.start, $0.end) }
    }

    /// The iOS Simulator can't play a video composition at all. If playback fails, play the
    /// pieces without it rather than show nothing; the saved video doesn't depend on it.
    private func watchForFailure(of item: AVPlayerItem, composition: AVComposition) {
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed, item.videoComposition != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, player.currentItem === item else { return }
                log.error("Preview failed, playing without the layout: \(String(describing: item.error), privacy: .public)")
                let plain = AVPlayerItem(asset: composition)
                let time = currentTime
                loopAtEnd(of: plain)
                player.replaceCurrentItem(with: plain)
                await player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
                player.play()
            }
        }
    }

    /// The recording plays over and over while it's being edited.
    private func loopAtEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }
    }

    private func refreshOverlays() {
        let style = recording.captionStyle
        captionRenderer = isVideo && style != .off && !captionLines.isEmpty && renderSize.width > 0
            ? CaptionRenderer(lines: captionLines, style: style, position: recording.captionPosition, size: renderSize)
            : nil
        mark = isVideo && showsMark && renderSize.width > 0 ? Watermark.make(for: renderSize) : nil
        lastRender = nil
    }

    private func thumbnailKey(_ piece: Piece) -> String {
        "\(piece.file)@\(Int(piece.start * 10))"
    }

    private func loadThumbnails() async {
        guard isVideo else { return }
        for piece in recording.pieces where thumbnails[thumbnailKey(piece)] == nil {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: recording.url(of: piece)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            if let image = try? await generator.image(at: CMTime(seconds: piece.start + 0.05, preferredTimescale: 600)).image {
                thumbnails[thumbnailKey(piece)] = image
            }
        }
    }

    // MARK: Playback

    func togglePlay() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        isPlaying = player.timeControlStatus != .paused
    }

    func playFromStart() {
        seek(to: 0)
        player.play()
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player.defaultRate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    // MARK: Scrubbing

    func beginScrub() {
        resumeAfterScrub = player.timeControlStatus != .paused
        player.pause()
    }

    /// Follows the finger: one seek at a time, always heading for the latest position.
    func scrub(to time: Double) {
        let target = min(max(0, time), max(0, length - 0.02))
        currentTime = target
        guard !isSeeking else {
            pendingSeek = target
            return
        }
        isSeeking = true
        let tolerance = CMTime(value: 1, timescale: 30)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isSeeking = false
                if let next = pendingSeek {
                    pendingSeek = nil
                    scrub(to: next)
                }
            }
        }
    }

    func endScrub() {
        pendingSeek = nil
        seek(to: currentTime)
        if resumeAfterScrub { player.play() }
        resumeAfterScrub = false
    }

    func seek(to time: Double) {
        let target = min(max(0, time), max(0, length - 0.02))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Selects a piece and shows the moment tapped in it.
    func select(_ pieceID: UUID?, at fraction: Double? = nil) {
        selectedPieceID = pieceID
        if let pieceID, let span = editList.span(of: pieceID) {
            seek(to: span.start + span.length * min(max(fraction ?? 0, 0), 0.999))
        }
    }

    // MARK: Edits

    private func edit(_ change: (inout Recording) -> Void) {
        undoSnapshot = recording
        canUndo = true
        change(&recording)
        lastRender = nil
        RecordingLibrary.shared.save(recording)
        Task { await rebuild(keepTime: true) }
    }

    func undo() {
        guard let undoSnapshot else { return }
        recording = undoSnapshot
        self.undoSnapshot = nil
        canUndo = false
        lastRender = nil
        if let selectedPieceID, !recording.pieces.contains(where: { $0.id == selectedPieceID }) {
            self.selectedPieceID = nil
        }
        RecordingLibrary.shared.save(recording)
        Task { await rebuild(keepTime: true) }
    }

    /// The selected piece can be split at the playhead when the playhead is inside it.
    var canSplit: Bool {
        guard let location = editList.location(at: currentTime),
              let piece = recording.pieces.first(where: { $0.id == location.pieceID }) else { return false }
        return location.source - piece.start > 0.3 && piece.end - location.source > 0.3
    }

    func split() {
        guard canSplit, let location = editList.location(at: currentTime),
              let index = recording.pieces.firstIndex(where: { $0.id == location.pieceID }) else { return }
        let piece = recording.pieces[index]
        let fraction = (location.source - piece.start) / max(piece.length, 0.01)
        let middle = piece.startProgress + (piece.endProgress - piece.startProgress) * fraction
        var first = piece
        first.end = location.source
        first.endProgress = middle
        var second = piece
        second.id = UUID()
        second.start = location.source
        second.startProgress = middle
        edit { $0.pieces.replaceSubrange(index...index, with: [first, second]) }
        selectedPieceID = second.id
    }

    func deletePiece(_ id: UUID) {
        guard let index = recording.pieces.firstIndex(where: { $0.id == id }), recording.pieces.count > 1 else { return }
        edit { $0.pieces.remove(at: index) }
        let next = min(index, recording.pieces.count - 1)
        selectedPieceID = recording.pieces[next].id
    }

    func trim(_ id: UUID, start: Double, end: Double) {
        guard let index = recording.pieces.firstIndex(where: { $0.id == id }) else { return }
        let sourceLength = sourceDuration(of: recording.pieces[index].file)
        var newStart = min(max(0, start), sourceLength)
        var newEnd = min(max(0, end), sourceLength)
        if newEnd - newStart < 0.3 {
            if start != recording.pieces[index].start { newStart = newEnd - 0.3 } else { newEnd = newStart + 0.3 }
        }
        guard abs(newStart - recording.pieces[index].start) > 0.01 || abs(newEnd - recording.pieces[index].end) > 0.01 else { return }
        edit {
            $0.pieces[index].start = max(0, newStart)
            $0.pieces[index].end = min(sourceLength, newEnd)
        }
    }

    func move(_ id: UUID, to destination: Int) {
        guard let index = recording.pieces.firstIndex(where: { $0.id == id }), index != destination else { return }
        edit {
            let piece = $0.pieces.remove(at: index)
            $0.pieces.insert(piece, at: min(max(0, destination), $0.pieces.count))
        }
    }

    func setRemovePauses(_ on: Bool) {
        guard on != recording.removePauses else { return }
        edit { $0.removePauses = on }
    }

    func setCaptionStyle(_ style: CaptionStyle) {
        guard style != recording.captionStyle else { return }
        UserDefaults.standard.set(style.rawValue, forKey: ReadingPreferences.takeCaptionStyleKey)
        edit { $0.captionStyle = style }
    }

    func setCaptionPosition(_ position: CaptionPosition) {
        guard position != recording.captionPosition else { return }
        UserDefaults.standard.set(position.rawValue, forKey: ReadingPreferences.takeCaptionPositionKey)
        edit { $0.captionPosition = position }
    }

    func rotate() {
        edit { $0.quarterTurns = ($0.quarterTurns + 1) % 4 }
    }

    /// The source's full length, the furthest a trim handle can go.
    func sourceDuration(of file: String) -> Double {
        if let known = sourceDurations[file] { return known }
        let longest = recording.pieces.filter { $0.file == file }.map(\.end).max() ?? 0
        let analysisLength = (analyses[file]?.envelope.count).map { Double($0) * TakeAnalysis.envelopeInterval } ?? 0
        let length = max(longest, analysisLength)
        sourceDurations[file] = length
        return length
    }

    // MARK: Pickups

    /// Recording more after a piece, or at the start with `index` -1, carrying on in the
    /// script from where that piece stopped.
    func pickup(after index: Int) -> Pickup {
        let progress: Double
        if recording.pieces.indices.contains(index) {
            let piece = recording.pieces[index]
            progress = EditList.pickupProgress(after: piece, analysis: analyses[piece.file], script: script)
        } else {
            progress = recording.pieces.first?.startProgress ?? 0
        }
        return Pickup(recordingID: recording.id, insertAt: index + 1, progress: progress,
                      title: recording.title, kind: recording.kind)
    }

    // MARK: Saving and sharing

    func save() { startRender(.save) }
    func share() { startRender(.share) }
    func cancelRender() { renderTask?.cancel() }

    func clearFailure() {
        renderState = .idle
    }

    func resume() {
        if !isRendering && hasItem { player.play() }
    }

    private func startRender(_ purpose: Purpose) {
        guard !isRendering, hasItem else { return }
        player.pause()
        renderState = .rendering(purpose, progress: 0)
        renderTask = Task {
            do {
                // Saving before the captions are ready waits for them rather than leaving them out.
                if recording.captionStyle != .off || !isVideo {
                    while analysisTask != nil {
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
                let url = try await renderedFile()
                try Task.checkCancellation()
                switch purpose {
                case .save:
                    try await RecordingExporter.saveToPhotos(url)
                    recording.savedAt = Date()
                    RecordingLibrary.shared.save(recording)
                    RatingService.shared.recordRecordingSaved()
                    renderState = .saved
                    try? await Task.sleep(for: .seconds(1.5))
                    if renderState == .saved { renderState = .idle }
                case .share:
                    let textFiles = isVideo && recording.captionStyle == .off
                        ? []
                        : RecordingExporter.writeTextFiles(next: url, lines: captionLines, editList: editList)
                    renderState = .idle
                    shareItems = ShareItems(urls: [url] + textFiles)
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    renderState = .idle
                    resume()
                } else {
                    renderState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func renderedFile() async throws -> URL {
        if let lastRender, FileManager.default.fileExists(atPath: lastRender.path) { return lastRender }
        // Makes sure the layout matches the latest edit before saving it.
        await rebuild(keepTime: true)
        guard let composed else { throw RecordingExporter.ExportError.nothingToSave }
        let url = try await RecordingExporter.render(
            recording, editList: editList, composed: composed,
            captions: captionRenderer, mark: mark, fileName: fileName
        ) { [weak self] progress in
            guard let self, case .rendering(let purpose, _) = renderState else { return }
            renderState = .rendering(purpose, progress: progress)
        }
        lastRender = url
        return url
    }

    // MARK: Leaving

    func close() {
        analysisTask?.cancel()
        renderTask?.cancel()
        rebuildTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        try? FileManager.default.removeItem(at: RecordingExporter.rendersFolder)
    }
}
#endif
