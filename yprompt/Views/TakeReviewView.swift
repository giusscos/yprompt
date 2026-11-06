//
//  TakeReviewView.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

// MARK: - Model

@Observable @MainActor
final class TakeReviewModel {
    enum CaptionStatus: Equatable {
        case working, ready, noWords, notAllowed, unavailable
    }

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

    let take: Take
    let player = AVPlayer()
    private(set) var item: AVPlayerItem?
    private(set) var duration: Double = 0
    /// The video as it's shown: upright, in pixels.
    private(set) var videoSize: CGSize = .zero
    private(set) var analysis: TakeAnalysis?
    private(set) var captionLines: [CaptionLine] = []
    private(set) var renderState: RenderState = .idle
    var shareItems: ShareItems?
    /// Captions are part of Pro; trimming and saving always work, so a take is never stuck.
    var captionsAllowed = false {
        didSet { refreshCaptions() }
    }

    var trimEnabled: Bool {
        didSet {
            UserDefaults.standard.set(trimEnabled, forKey: ReadingPreferences.takeTrimKey)
            keepPlayheadInRange()
        }
    }
    var captionStyle: CaptionStyle {
        didSet {
            UserDefaults.standard.set(captionStyle.rawValue, forKey: ReadingPreferences.takeCaptionStyleKey)
            refreshCaptions()
        }
    }
    var captionPosition: CaptionPosition {
        didSet {
            UserDefaults.standard.set(captionPosition.rawValue, forKey: ReadingPreferences.takeCaptionPositionKey)
            refreshCaptions()
        }
    }

    @ObservationIgnored private let script: ScriptWords
    @ObservationIgnored private let fileName: String
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var analysisTask: Task<TakeAnalysis, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var lastRender: (key: RenderKey, url: URL)?
    /// Draws the preview's captions; the saved video uses the same drawing.
    private(set) var captionRenderer: CaptionRenderer?

    private struct RenderKey: Equatable {
        var range: ClosedRange<Double>
        var captions: TakeExporter.Captions?
    }

    init(take: Take, script: ScriptWords, title: String) {
        self.take = take
        self.script = script
        let defaults = UserDefaults.standard
        trimEnabled = defaults.object(forKey: ReadingPreferences.takeTrimKey) as? Bool ?? true
        captionStyle = CaptionStyle(rawValue: defaults.string(forKey: ReadingPreferences.takeCaptionStyleKey) ?? "") ?? .lyrics
        captionPosition = CaptionPosition(rawValue: defaults.string(forKey: ReadingPreferences.takeCaptionPositionKey) ?? "") ?? .bottom
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fileName = cleaned.isEmpty ? "yPrompt Take" : String(cleaned.prefix(60))
    }

    // MARK: State

    var captionStatus: CaptionStatus {
        guard let analysis else { return .working }
        switch analysis.speech {
        case .notAllowed: return .notAllowed
        case .unavailable: return .unavailable
        case .recognized: return captionLines.isEmpty ? .noWords : .ready
        }
    }

    var trimRange: ClosedRange<Double>? { analysis?.trimRange(duration: duration) }

    /// The part of the take that's kept.
    var range: ClosedRange<Double> {
        (trimEnabled ? trimRange : nil) ?? 0...max(duration, 0.1)
    }

    /// The captions to draw and save, or nil for none.
    var activeCaptions: TakeExporter.Captions? {
        guard captionsAllowed, captionStyle != .off, !captionLines.isEmpty else { return nil }
        return TakeExporter.Captions(lines: captionLines, style: captionStyle, position: captionPosition)
    }

    var isRendering: Bool {
        if case .rendering = renderState { return true }
        return false
    }

    // MARK: Loading

    func load() async {
        guard item == nil else { return }
        let asset = AVURLAsset(url: take.url)
        duration = (try? await asset.load(.duration))?.seconds ?? 0
        videoSize = (try? await TakeExporter.uprightSize(of: asset)) ?? .zero

        let item = AVPlayerItem(asset: asset)
        self.item = item
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playFromStart() }
        }
        keepPlayheadInRange()
        player.play()

        let script = script
        let url = take.url
        let task = Task { await TakeTranscriber.analyze(url: url, script: script) }
        analysisTask = task
        let analysis = await task.value
        guard !Task.isCancelled else { return }
        captionLines = CaptionTrack.lines(spoken: analysis.words, script: script)
        self.analysis = analysis
        keepPlayheadInRange()
        refreshCaptions()
    }

    private func refreshCaptions() {
        guard let captions = activeCaptions, videoSize.width > 0 else {
            captionRenderer = nil
            return
        }
        captionRenderer = CaptionRenderer(lines: captions.lines, style: captions.style,
                                          position: captions.position, size: videoSize)
    }

    // MARK: Playback

    /// Plays only the kept part, over and over.
    private func keepPlayheadInRange() {
        guard let item else { return }
        let range = range
        item.forwardPlaybackEndTime = CMTime(seconds: range.upperBound, preferredTimescale: 600)
        let now = player.currentTime().seconds
        if now < range.lowerBound || now > range.upperBound - 0.05 {
            playFromStart()
        }
    }

    private func playFromStart() {
        guard !isRendering, shareItems == nil else { return }
        let start = CMTime(seconds: range.lowerBound, preferredTimescale: 600)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func resume() {
        guard !isRendering, item != nil else { return }
        player.play()
    }

    // MARK: Saving and sharing

    func save() { startRender(.save) }
    func share() { startRender(.share) }

    func cancelRender() {
        renderTask?.cancel()
    }

    func clearFailure() {
        renderState = .idle
        resume()
    }

    private func startRender(_ purpose: Purpose) {
        guard !isRendering, item != nil else { return }
        player.pause()
        renderState = .rendering(purpose, progress: 0)
        renderTask = Task {
            do {
                // Saving before the captions are ready waits for them rather than leaving them out.
                if captionsAllowed && captionStyle != .off { _ = await analysisTask?.value }
                let url = try await renderedClip()
                try Task.checkCancellation()
                switch purpose {
                case .save:
                    try await TakeExporter.saveToPhotos(url)
                    TakeStore.discard(take)
                    renderState = .saved
                case .share:
                    var urls = [url]
                    if let captions = activeCaptions {
                        let srt = url.deletingPathExtension().appendingPathExtension("srt")
                        try CaptionTrack.srt(captions.lines, in: range).write(to: srt, atomically: true, encoding: .utf8)
                        urls.append(srt)
                    }
                    renderState = .idle
                    shareItems = ShareItems(urls: urls)
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    renderState = .idle
                    resume()
                } else {
                    // Playback resumes once the reader has seen the message.
                    renderState = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// The same settings give the same clip, so Share then Save renders once.
    private func renderedClip() async throws -> URL {
        let key = RenderKey(range: range, captions: activeCaptions)
        if let lastRender, lastRender.key == key, FileManager.default.fileExists(atPath: lastRender.url.path) {
            return lastRender.url
        }
        let url = try await TakeExporter.render(
            take: take, range: key.range, captions: key.captions, fileName: fileName
        ) { [weak self] progress in
            guard let self, case .rendering(let purpose, _) = renderState else { return }
            renderState = .rendering(purpose, progress: progress)
        }
        lastRender = (key, url)
        return url
    }

    // MARK: Leaving

    func discard() {
        close()
        TakeStore.discard(take)
    }

    func close() {
        analysisTask?.cancel()
        renderTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        try? FileManager.default.removeItem(at: TakeExporter.rendersFolder)
    }
}

// MARK: - View

/// Shown when a recording stops: the take plays trimmed and captioned, ready to save or retake.
struct TakeReviewView: View {
    @State private var model: TakeReviewModel
    @Environment(StoreKitService.self) private var storeKit
    @Environment(\.openURL) private var openURL
    @State private var confirmingDiscard = false
    @State private var confirmingRetake = false
    @State private var showingPaywall = false
    private let onRetake: () -> Void
    private let onFinish: () -> Void

    init(take: Take, script: ScriptWords, title: String, onRetake: @escaping () -> Void, onFinish: @escaping () -> Void) {
        _model = State(initialValue: TakeReviewModel(take: take, script: script, title: title))
        self.onRetake = onRetake
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            TakePlayerView(player: model.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if let renderer = model.captionRenderer, !model.isRendering {
                        CaptionOverlay(player: model.player, renderer: renderer, videoSize: model.videoSize)
                    }
                }
                .overlay {
                    if model.item == nil { ProgressView() }
                }
                .accessibilityLabel("Take preview")
            controls
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task {
            model.captionsAllowed = storeKit.isPremium
            await model.load()
        }
        .onChange(of: storeKit.isPremium) { _, premium in model.captionsAllowed = premium }
        .onChange(of: model.renderState) { _, state in
            guard state == .saved else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                onFinish()
            }
        }
        .sheet(item: $model.shareItems, onDismiss: { model.resume() }) { items in
            ActivityView(items: items.urls)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView().environment(storeKit)
        }
        .confirmationDialog("Discard this take?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Take", role: .destructive) {
                model.discard()
                onFinish()
            }
        } message: {
            Text("It hasn't been saved to Photos.")
        }
        .confirmationDialog("Record again?", isPresented: $confirmingRetake, titleVisibility: .visible) {
            Button("Delete and Retake", role: .destructive) {
                model.discard()
                onRetake()
            }
        } message: {
            Text("This take will be deleted, and the script goes back to where it began.")
        }
        .alert("Couldn't Save", isPresented: Binding(
            get: { if case .failed = model.renderState { true } else { false } },
            set: { if !$0 { model.clearFailure() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let message) = model.renderState { Text(message) }
        }
        .onDisappear { model.close() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { confirmingDiscard = true } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .ypGlassEffect(cornerRadius: 22)
            .accessibilityLabel("Discard Take")
            .disabled(model.isRendering || model.renderState == .saved)

            Spacer()
            VStack(spacing: 2) {
                Text("Your Take").font(.headline)
                Text(Duration.seconds(model.range.upperBound - model.range.lowerBound),
                     format: .time(pattern: .minuteSecond))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: model.range)
            }
            Spacer()

            Button { model.share() } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .ypGlassEffect(cornerRadius: 22)
            .accessibilityLabel("Share")
            .disabled(model.isRendering || model.item == nil || model.renderState == .saved)
        }
        .padding(.top, 8)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $model.trimEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trim Silence")
                    Text(trimDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.accentColor)

            Divider()

            captionControls

            actionRow
                .padding(.top, 4)
        }
        .padding(16)
        .ypGlassEffect(cornerRadius: 24)
        .disabled(model.renderState == .saved)
    }

    private var trimDetail: String {
        guard model.analysis != nil else { return String(localized: "Finding where you start speaking…") }
        guard model.trimEnabled else { return String(localized: "The whole recording is kept.") }
        guard let trim = model.trimRange else { return String(localized: "Nothing to trim.") }
        return String(format: String(localized: "Cuts %.1f s at the start and %.1f s at the end"),
                      trim.lowerBound, max(0, model.duration - trim.upperBound))
    }

    @ViewBuilder
    private var captionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Captions")
                Spacer()
                if !model.captionsAllowed {
                    Button { showingPaywall = true } label: {
                        Label("Unlock with Pro", systemImage: "lock.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            Picker("Captions", selection: Binding(
                get: { model.captionsAllowed ? model.captionStyle : .off },
                set: { model.captionStyle = $0 }
            )) {
                ForEach(CaptionStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.captionsAllowed)

            if model.captionsAllowed && model.captionStyle != .off {
                Picker("Position", selection: $model.captionPosition) {
                    ForEach(CaptionPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                captionStatusRow
            }
        }
    }

    @ViewBuilder
    private var captionStatusRow: some View {
        switch model.captionStatus {
        case .ready:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Making captions…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .notAllowed:
            HStack {
                Text("Allow Speech Recognition in Settings to make captions.")
                Spacer()
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .unavailable:
            Text("Captions aren't available for this take's language.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .noWords:
            Text("No words were heard in this take.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch model.renderState {
        case .rendering(let purpose, let progress):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(purpose == .save ? "Saving…" : "Preparing…")
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: progress)
                        .tint(.white)
                }
                Button("Cancel") { model.cancelRender() }
                    .ypGlassButtonStyle()
            }
            .frame(minHeight: 50)
        case .saved:
            Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, minHeight: 50)
                .transition(.opacity)
        case .idle, .failed:
            HStack(spacing: 12) {
                Button { confirmingRetake = true } label: {
                    Label("Retake", systemImage: "arrow.counterclockwise")
                        .lineLimit(1)
                        .frame(minHeight: 36)
                        .padding(.horizontal, 4)
                }
                .ypGlassButtonStyle()

                Button { model.save() } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .ypGlassProminentButtonStyle()
                .disabled(model.item == nil)
            }
        }
    }
}

// MARK: - Player

private struct TakePlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The captions over the playing take, drawn by the renderer the saved video uses.
private struct CaptionOverlay: View {
    let player: AVPlayer
    let renderer: CaptionRenderer
    let videoSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                let frame = AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: geometry.size))
                if videoSize.width > 0, let caption = renderer.image(at: player.currentTime().seconds) {
                    let scale = frame.width / videoSize.width
                    let width = CGFloat(caption.image.width) * scale
                    let height = CGFloat(caption.image.height) * scale
                    // The renderer measures from the bottom left, like the video frame.
                    Image(decorative: caption.image, scale: 1)
                        .resizable()
                        .frame(width: width, height: height)
                        .position(x: frame.minX + caption.origin.x * scale + width / 2,
                                  y: frame.minY + (videoSize.height - caption.origin.y) * scale - height / 2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Share sheet

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
