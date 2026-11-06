//
//  RecordingEditorView.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Opens after every take and from the Recordings tab: watch the recording, cut it into
/// pieces, trim, reorder, remove pauses, caption it, and record more where it left off.
struct RecordingEditorView: View {
    @State private var model: RecordingEditorModel?
    @Environment(StoreKitService.self) private var storeKit
    @Environment(\.openURL) private var openURL
    @State private var confirmingDeleteRecording = false
    @State private var showingPaywall = false

    let selection: RecordingSelection
    let script: ScriptWords?
    /// Nil when there's no reading screen to record more from (the script was deleted).
    let onRecordMore: ((Pickup) -> Void)?
    let onClose: () -> Void

    var body: some View {
        Group {
            if let model {
                EditorContent(model: model, canRecordMore: onRecordMore != nil && script != nil,
                              onRecordMore: { pickup in model.close(); onRecordMore?(pickup) },
                              onDeleteRecording: { confirmingDeleteRecording = true },
                              onRemoveMark: { showingPaywall = true },
                              onClose: { model.close(); onClose() })
            } else {
                ContentUnavailableView("Recording Not Found", systemImage: "film.stack",
                                       description: Text("It may have been deleted."))
                    .overlay(alignment: .topLeading) {
                        Button("Done") { onClose() }.padding()
                    }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard model == nil, let recording = RecordingLibrary.shared.recording(selection.recordingID) else { return }
            let model = RecordingEditorModel(recording: recording, script: script ?? ScriptWords(text: ""),
                                             selectedPieceID: selection.pieceID)
            model.showsMark = !storeKit.isPremium
            self.model = model
        }
        .task(id: model == nil) { await model?.load() }
        .onChange(of: storeKit.isPremium) { _, premium in model?.showsMark = !premium }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(context: .removeMark).environment(storeKit)
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmingDeleteRecording, titleVisibility: .visible) {
            Button("Delete Recording", role: .destructive) {
                if let model {
                    model.close()
                    RecordingLibrary.shared.delete(model.recording)
                }
                onClose()
            }
        } message: {
            Text("It's the last piece, so the whole recording goes. This can't be undone.")
        }
    }
}

private struct EditorContent: View {
    @Bindable var model: RecordingEditorModel
    let canRecordMore: Bool
    let onRecordMore: (Pickup) -> Void
    let onDeleteRecording: () -> Void
    let onRemoveMark: () -> Void
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 10) {
            header
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            transport
            PieceStripView(model: model)
                .frame(height: 58)
            pieceToolbar
            options
            bottomButtons
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .sheet(item: $model.shareItems, onDismiss: { model.resume() }) { items in
            ActivityView(items: items.urls)
        }
        .alert("Couldn't Save", isPresented: Binding(
            get: { if case .failed = model.renderState { true } else { false } },
            set: { if !$0 { model.clearFailure() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let message) = model.renderState { Text(message) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button("Done", action: onClose)
                .font(.headline)
                .ypGlassButtonStyle()
                .disabled(model.isRendering)
            Spacer()
            VStack(spacing: 2) {
                Text(model.recording.title).font(.headline).lineLimit(1)
                Text(Duration.seconds(model.length), format: .time(pattern: .minuteSecond))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: model.length)
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
            .disabled(model.isRendering || !model.hasItem)
        }
        .padding(.top, 8)
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        if model.isVideo {
            GeometryReader { geometry in
                let size = model.renderSize
                let frame = size.width > 0
                    ? AVMakeRect(aspectRatio: size, insideRect: CGRect(origin: .zero, size: geometry.size))
                    : CGRect(origin: .zero, size: geometry.size)
                ZStack(alignment: .topLeading) {
                    PlayerLayerView(player: model.player)
                    if let renderer = model.captionRenderer, !model.isRendering {
                        CaptionOverlay(player: model.player, renderer: renderer, videoSize: size)
                    }
                    if let mark = model.mark {
                        markOverlay(mark, in: frame.size, videoSize: size)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .overlay(alignment: .bottomTrailing) {
                    Button { withAnimation(.snappy) { model.rotate() } } label: {
                        Image(systemName: "rotate.right")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .ypGlassEffect(cornerRadius: 22)
                    .padding(10)
                    .accessibilityLabel("Rotate")
                    .disabled(model.isRendering)
                }
                .position(x: frame.midX, y: frame.midY)
                .onTapGesture { model.togglePlay() }
            }
            .overlay { if !model.hasItem { ProgressView() } }
        } else {
            audioCard
        }
    }

    /// The mark as it will be saved, with a way to remove it.
    private func markOverlay(_ mark: Watermark, in displaySize: CGSize, videoSize: CGSize) -> some View {
        let scale = videoSize.width > 0 ? displaySize.width / videoSize.width : 1
        return HStack(spacing: 6) {
            Image(decorative: mark.image, scale: 1)
                .resizable()
                .frame(width: CGFloat(mark.image.width) * scale, height: CGFloat(mark.image.height) * scale)
            Button("Remove", action: onRemoveMark)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(.leading, mark.origin.x * scale)
        .padding(.top, (videoSize.height - mark.origin.y - CGFloat(mark.image.height)) * scale)
    }

    private var audioCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: model.isPlaying)
            Text(model.currentLine?.text ?? " ")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 80)
                .animation(.easeInOut(duration: 0.15), value: model.currentLine?.text)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ypGlassEffect(cornerRadius: 24)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlay() }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                   in: 0...max(model.length, 0.1))
                .tint(.white)
            Text(Duration.seconds(model.currentTime), format: .time(pattern: .minuteSecond))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .disabled(!model.hasItem || model.isRendering)
    }

    // MARK: Pieces

    private var pieceToolbar: some View {
        HStack(spacing: 8) {
            toolButton("Undo", icon: "arrow.uturn.backward", enabled: model.canUndo) { model.undo() }
            Spacer()
            if let index = model.selectedIndex {
                toolButton("Split", icon: "scissors", enabled: model.canSplit) { model.split() }
                toolButton("Delete", icon: "trash", enabled: true) {
                    if model.recording.pieces.count > 1 {
                        model.deletePiece(model.recording.pieces[index].id)
                    } else {
                        onDeleteRecording()
                    }
                }
                if canRecordMore {
                    toolButton("Add After", icon: "plus.rectangle.on.rectangle", enabled: true) {
                        onRecordMore(model.pickup(after: index))
                    }
                }
            } else {
                Text("Tap a piece to edit it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.isRendering)
    }

    private func toolButton(_ title: LocalizedStringKey, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 68, height: 44)
        }
        .buttonStyle(.plain)
        .ypGlassEffect(cornerRadius: 16)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { model.recording.removePauses }, set: { model.setRemovePauses($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove Pauses")
                    Text("Cuts the silences between your sentences.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.accentColor)

            HStack(spacing: 10) {
                Text(model.isVideo ? "Captions" : "Transcript")
                Spacer()
                if model.isVideo {
                    Picker("Captions", selection: Binding(get: { model.recording.captionStyle },
                                                          set: { model.setCaptionStyle($0) })) {
                        ForEach(CaptionStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    if model.recording.captionStyle != .off {
                        Menu {
                            Picker("Position", selection: Binding(get: { model.recording.captionPosition },
                                                                  set: { model.setCaptionPosition($0) })) {
                                ForEach(CaptionPosition.allCases) { Text($0.title).tag($0) }
                            }
                        } label: {
                            Image(systemName: model.recording.captionPosition == .bottom
                                  ? "rectangle.bottomhalf.inset.filled" : "rectangle.center.inset.filled")
                                .font(.title3)
                        }
                        .accessibilityLabel("Position")
                    }
                }
            }
            captionStatus
        }
        .padding(14)
        .ypGlassEffect(cornerRadius: 20)
        .disabled(model.isRendering)
    }

    @ViewBuilder
    private var captionStatus: some View {
        switch model.speechStatus {
        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.isVideo ? "Making captions…" : "Writing the transcript…")
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
            Text("Captions aren't available for this recording's language.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .recognized:
            if model.captionLines.isEmpty {
                Text("No words were heard in this recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottomButtons: some View {
        switch model.renderState {
        case .rendering(let purpose, let progress):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(purpose == .save ? "Saving…" : "Preparing…")
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: progress).tint(.white)
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
        case .idle, .failed:
            HStack(spacing: 12) {
                if canRecordMore {
                    Button { onRecordMore(model.pickup(after: model.recording.pieces.count - 1)) } label: {
                        Label("Record More", systemImage: model.isVideo ? "video.badge.plus" : "mic.badge.plus")
                            .lineLimit(1)
                            .frame(minHeight: 36)
                            .padding(.horizontal, 4)
                    }
                    .ypGlassButtonStyle()
                }
                if model.isVideo {
                    Button { model.save() } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .ypGlassProminentButtonStyle()
                    .disabled(!model.hasItem)
                } else {
                    Button { model.share() } label: {
                        Label("Share Audio", systemImage: "square.and.arrow.up")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .ypGlassProminentButtonStyle()
                    .disabled(!model.hasItem)
                }
            }
        }
    }
}

// MARK: - Piece strip

/// The recording's pieces side by side, each as wide as its share of the length. Tap to
/// select and jump there, drag a selected piece's ends to trim, hold and drag to move it.
private struct PieceStripView: View {
    @Bindable var model: RecordingEditorModel
    @State private var trimDrag: (id: UUID, isStart: Bool, seconds: Double)?

    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let pieces = model.recording.pieces
            let widths = tileWidths(total: geometry.size.width, pieces: pieces)
            ZStack(alignment: .topLeading) {
                HStack(spacing: spacing) {
                    ForEach(Array(pieces.enumerated()), id: \.element.id) { index, piece in
                        tile(piece, index: index, width: widths[index])
                    }
                }
                playhead(widths: widths, pieces: pieces)
            }
        }
    }

    private func tileWidths(total: CGFloat, pieces: [Piece]) -> [CGFloat] {
        let available = max(0, total - spacing * CGFloat(max(0, pieces.count - 1)))
        let lengths = pieces.map { model.editList.span(of: $0.id)?.length ?? $0.length }
        let sum = max(lengths.reduce(0, +), 0.01)
        let raw = lengths.map { max(28, available * CGFloat($0 / sum)) }
        let scale = min(1, available / max(raw.reduce(0, +), 1))
        return raw.map { $0 * scale }
    }

    private func tile(_ piece: Piece, index: Int, width: CGFloat) -> some View {
        let isSelected = model.selectedPieceID == piece.id
        return ZStack {
            tileContent(piece)
                .frame(width: width, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                HStack {
                    handle(piece, isStart: true, width: width)
                    Spacer(minLength: 0)
                    handle(piece, isStart: false, width: width)
                }
            }
            if let drag = trimDrag, drag.id == piece.id {
                Text(Duration.seconds(max(0.3, piece.length - (drag.isStart ? drag.seconds : -drag.seconds))),
                     format: .time(pattern: .minuteSecond))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(4)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        .frame(width: width, height: 58)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            model.select(piece.id, at: Double(location.x / max(width, 1)))
        }
        .draggable(piece.id.uuidString) {
            tileContent(piece)
                .frame(width: min(width, 80), height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.move(id, to: index)
            return true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Piece \(index + 1)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func tileContent(_ piece: Piece) -> some View {
        if model.isVideo {
            if let image = model.thumbnail(for: piece) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.12)
            }
        } else {
            WaveformView(levels: levels(for: piece))
                .background(Color.accentColor.opacity(0.25))
        }
    }

    /// Loudness across the piece, for its waveform.
    private func levels(for piece: Piece) -> [Float] {
        guard let envelope = model.analyses[piece.file]?.envelope, !envelope.isEmpty else { return [] }
        let step = TakeAnalysis.envelopeInterval
        let first = max(0, Int(piece.start / step))
        let last = min(envelope.count, Int(piece.end / step))
        guard last > first else { return [] }
        return Array(envelope[first..<last])
    }

    /// Drag outward to bring back cut material, inward to cut more.
    private func handle(_ piece: Piece, isStart: Bool, width: CGFloat) -> some View {
        Capsule()
            .fill(Color.yellow)
            .frame(width: 8, height: 34)
            .padding(.horizontal, 2)
            .frame(width: 22, height: 58)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let secondsPerPoint = piece.length / Double(max(width, 1))
                        trimDrag = (piece.id, isStart, Double(value.translation.width) * secondsPerPoint)
                    }
                    .onEnded { value in
                        let secondsPerPoint = piece.length / Double(max(width, 1))
                        let delta = Double(value.translation.width) * secondsPerPoint
                        trimDrag = nil
                        if isStart {
                            model.trim(piece.id, start: piece.start + delta, end: piece.end)
                        } else {
                            model.trim(piece.id, start: piece.start, end: piece.end + delta)
                        }
                    }
            )
            .accessibilityLabel(isStart ? "Trim start" : "Trim end")
    }

    private func playhead(widths: [CGFloat], pieces: [Piece]) -> some View {
        var x: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            guard let span = model.editList.span(of: piece.id) else { continue }
            if model.currentTime < span.end || index == pieces.count - 1 {
                let fraction = span.length > 0 ? min(max((model.currentTime - span.start) / span.length, 0), 1) : 0
                x += widths[index] * CGFloat(fraction)
                break
            }
            x += widths[index] + spacing
        }
        return Rectangle()
            .fill(.white)
            .frame(width: 2, height: 66)
            .shadow(radius: 2)
            .offset(x: x - 1, y: -4)
            .allowsHitTesting(false)
    }
}

private struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let bars = max(1, Int(size.width / 3))
            for bar in 0..<bars {
                let index = min(levels.count - 1, bar * levels.count / bars)
                let level = CGFloat(VoiceScrollService.normalize(levels[index]))
                let height = max(2, level * size.height * 0.9)
                let rect = CGRect(x: CGFloat(bar) * 3, y: (size.height - height) / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.85)))
            }
        }
    }
}

// MARK: - Player and overlays

private struct PlayerLayerView: UIViewRepresentable {
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

/// The captions over the playing recording, drawn by the renderer the saved video uses.
private struct CaptionOverlay: View {
    let player: AVPlayer
    let renderer: CaptionRenderer
    let videoSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                if videoSize.width > 0, let caption = renderer.image(at: player.currentTime().seconds) {
                    let scale = geometry.size.width / videoSize.width
                    let width = CGFloat(caption.image.width) * scale
                    let height = CGFloat(caption.image.height) * scale
                    // The renderer measures from the bottom left, like the video frame.
                    Image(decorative: caption.image, scale: 1)
                        .resizable()
                        .frame(width: width, height: height)
                        .position(x: caption.origin.x * scale + width / 2,
                                  y: (videoSize.height - caption.origin.y) * scale - height / 2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
