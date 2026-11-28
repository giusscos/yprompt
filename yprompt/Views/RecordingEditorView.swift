//
//  RecordingEditorView.swift
//  yprompt
//

#if os(iOS) || os(macOS)
import AVFoundation
import PhotosUI
import StoreKit
import SwiftUI
import TipKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Opens after every take and from the Recordings tab: watch the recording, cut it into
/// pieces, trim, reorder, add clips, remove pauses, caption and style it, and record more
/// where it left off.
struct RecordingEditorView: View {
    @State private var model: RecordingEditorModel?
    @Environment(StoreKitService.self) private var storeKit
    @Environment(\.openURL) private var openURL
    @State private var confirmingDeleteRecording = false
    /// The paywall, opened for a reason: the mark, or the delivery report.
    @State private var paywallContext: PaywallView.Context?
    /// Set by each save to Photos; the rating request waits on it.
    @State private var reviewAfterSave: UUID?

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
                              onUpgrade: { context in
                                  paywallContext = context
                              },
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
            model.hasPro = storeKit.isPremium
            self.model = model
        }
        .task(id: model == nil) { await model?.load() }
        #if os(macOS)
        // Another recording was picked in the list, or the window closed.
        .onDisappear { model?.close() }
        #endif
        .onChange(of: storeKit.isPremium) { _, premium in
            model?.showsMark = !premium
            model?.hasPro = premium
        }
        .onChange(of: model?.renderState) { _, state in
            if state == .saved { reviewAfterSave = UUID() }
        }
        .task(id: reviewAfterSave) {
            // After "Saved to Photos" has shown for a moment. Leaving the editor cancels it.
            guard reviewAfterSave != nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            reviewAfterSave = nil
            guard let model, paywallContext == nil, !confirmingDeleteRecording, model.shareItems == nil else { return }
            guard model.renderState == .saved || model.renderState == .idle else { return }
            RatingService.shared.requestIfAppropriate(after: .zero)
        }
        .sheet(item: $paywallContext) { context in
            PaywallView(context: context).environment(storeKit)
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
    private let captionsTip = CaptionsTip()
    private let removePausesTip = RemovePausesTip()
    private let timelineTip = TimelineTip()
    private let saveWithoutMarkTip = SaveWithoutMarkTip()
    private var deliveryTip: DeliveryTip { DeliveryTip(isPro: model.hasPro) }
    private let captionStyleTip = CaptionStyleTip()
    private let addClipTip = AddClipTip()
    /// This visit's tip. At most one per visit, picked once the recording has loaded, or once
    /// its words have been heard if nothing fitted before.
    @State private var editorTip: EditorTip?
    @State private var waitedForWords = false
    @State private var isPickingTip = false
    #if os(macOS)
    static let alwaysSideBySide = true
    #else
    static let alwaysSideBySide = false
    #endif

    @Bindable var model: RecordingEditorModel
    let canRecordMore: Bool
    let onRecordMore: (Pickup) -> Void
    let onDeleteRecording: () -> Void
    let onUpgrade: (PaywallView.Context) -> Void
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var showingCaptionStyle = false
    @State private var showingDelivery = false
    /// Where an added clip goes, chosen before Photos or Files opens.
    @State private var clipIndex = 0
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        GeometryReader { geometry in
            // The Mac window keeps a readable minimum size, so it always fits side by side.
            if Self.alwaysSideBySide || geometry.size.width > geometry.size.height {
                // Landscape: the recording on one side, everything to edit it on the other.
                HStack(spacing: 16) {
                    VStack(spacing: 10) {
                        preview
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        transport
                    }
                    .frame(width: geometry.size.width * 0.52)
                    VStack(spacing: 10) {
                        header
                        ScrollView {
                            VStack(spacing: 12) {
                                strip
                                pieceToolbar
                                options
                            }
                            .padding(.top, 4)
                        }
                        .scrollIndicators(.hidden)
                        bottomButtons
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    header
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transport
                    strip
                    pieceToolbar
                    options
                    bottomButtons
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        #if os(iOS)
        .sheet(item: $model.shareItems, onDismiss: { model.resume() }) { items in
            ActivityView(items: items.urls)
        }
        #else
        .background { editorShortcuts }
        #endif
        .alert("Couldn't Save", isPresented: Binding(
            get: { if case .failed = model.renderState { true } else { false } },
            set: { if !$0 { model.clearFailure() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let message) = model.renderState { Text(message) }
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .videos,
                      preferredItemEncoding: .current)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            let index = clipIndex
            Task { await model.addClip(item, at: index) }
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: model.isVideo ? [.movie] : [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            let index = clipIndex
            Task { await model.addClip(from: url, at: index) }
        }
        .task {
            TipState.editorOpened()
            try? await Task.sleep(for: .milliseconds(800))
            await pickEditorTip()
        }
        .onChange(of: model.deliveryReport != nil) { _, hasReport in
            if hasReport { Task { await pickEditorTip() } }
        }
        .onChange(of: model.isAnalyzing) { _, analyzing in
            if !analyzing { Task { await pickEditorTip() } }
        }
    }

    // MARK: Tips

    /// The first tip that fits this visit, of those not yet closed or acted on.
    private func pickEditorTip() async {
        guard editorTip == nil, !model.isRendering, model.hasItem else { return }
        let visits = TipState.editorVisits
        let report = model.deliveryReport
        var candidates: [(EditorTip, any Tip)] = []
        if model.isVideo, model.recording.captionStyle == .off {
            candidates.append((.captions, captionsTip))
        }
        if let report, !report.pauses.isEmpty, !model.recording.removePauses {
            RemovePausesTip.pauses = report.pauses.count
            candidates.append((.removePauses, removePausesTip))
        }
        candidates.append((.timeline, timelineTip))
        if !model.hasPro, model.isVideo, TipState.markedSaves >= 1 {
            candidates.append((.saveWithoutMark, saveWithoutMarkTip))
        }
        if report?.wordsPerMinute != nil, visits >= 2 {
            candidates.append((.delivery, deliveryTip))
        }
        if model.isVideo, model.recording.captionStyle != .off, model.recording.look == CaptionLook(), visits >= 2 {
            candidates.append((.captionStyle, captionStyleTip))
        }
        if visits >= 3, model.recording.pieces.count > 0 {
            candidates.append((.addClip, addClipTip))
        }
        // The pauses aren't known until the words are: while they're being heard, wait for them
        // rather than settle for the timeline tip.
        if report == nil, model.speechStatus == nil, !waitedForWords {
            waitedForWords = true
            if await TipState.first(of: candidates) == .timeline { return }
        }
        guard editorTip == nil, !isPickingTip else { return }
        isPickingTip = true
        defer { isPickingTip = false }
        let picked = await TipState.first(of: candidates)
        guard editorTip == nil, !model.isRendering else { return }
        editorTip = picked
    }

    private func tip(_ which: EditorTip) -> (any Tip)? {
        guard editorTip == which else { return nil }
        return switch which {
        case .captions: captionsTip
        case .removePauses: removePausesTip
        case .timeline: timelineTip
        case .saveWithoutMark: saveWithoutMarkTip
        case .delivery: deliveryTip
        case .captionStyle: captionStyleTip
        case .addClip: addClipTip
        }
    }

    /// A tip's button: the tip closes first, then what it offers happens.
    private func handleEditorTip(_ action: Tip.Action) {
        if let editorTip, let current = tip(editorTip) { current.done() }
        let id = action.id
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            switch id {
            case "lyrics": model.setCaptionStyle(.lyrics)
            case "remove": model.setRemovePauses(true)
            case "pro": onUpgrade(.removeMark)
            case "report": if model.hasPro { showingDelivery = true } else { onUpgrade(.deliveryReport) }
            case "style": showingCaptionStyle = true
            default: break
            }
        }
    }

    private var strip: some View {
        TimelineStripView(model: model) {
            addMenuItems(at: model.recording.pieces.count)
        }
        .frame(height: TimelineStripView<EmptyView>.height)
        .ypPopoverTip(tip(.timeline), arrowEdge: .top, action: handleEditorTip)
        .disabled(model.isRendering)
        .alert("Couldn't Add the Clip", isPresented: Binding(
            get: { model.clipError != nil },
            set: { if !$0 { model.clipError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.clipError ?? "")
        }
    }

    /// Record more, or add a video (or, to an audio recording, a sound) from Photos or Files,
    /// placed at `index` among the pieces.
    @ViewBuilder
    private func addMenuItems(at index: Int) -> some View {
        if canRecordMore {
            Button { addClipTip.done(); onRecordMore(model.pickup(after: index - 1)) } label: {
                Label("Record More", systemImage: model.isVideo ? "video.badge.plus" : "mic.badge.plus")
            }
        }
        Button {
            addClipTip.done()
            clipIndex = index
            showingPhotoPicker = true
        } label: {
            Label("Add from Photos", systemImage: "photo.on.rectangle")
        }
        Button {
            addClipTip.done()
            clipIndex = index
            showingFileImporter = true
        } label: {
            Label("Add from Files", systemImage: "folder")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            #if os(iOS)
            Button("Done", action: onClose)
                .font(.headline)
                .ypGlassButtonStyle()
                .disabled(model.isRendering)
            #endif
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
            #if os(macOS)
            // The share menu opens from the button once the file is ready.
            .background {
                SharePickerAnchor(items: $model.shareItems) { model.resume() }
            }
            .help("Share")
            #endif
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
                        CaptionOverlay(renderer: renderer, videoSize: size) {
                            // The player's own clock while playing; the playhead while paused or scrubbing.
                            model.isPlaying ? model.player.currentTime().seconds : model.currentTime
                        }
                    }
                    if let mark = model.mark {
                        markOverlay(mark, in: frame.size, videoSize: size)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .animation(.snappy(duration: 0.35), value: model.renderSize)
                // Bottom right: on a tall video the mark and its Remove button span the top.
                .overlay(alignment: .bottomTrailing) {
                    Button { withAnimation(.snappy) { model.rotate() } } label: {
                        Image(systemName: "rotate.right")
                            .font(.headline)
                            .symbolEffect(.bounce, value: model.recording.quarterTurns)
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
            Button("Remove") { onUpgrade(.removeMark) }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(.leading, mark.origin.x * scale)
        .padding(.top, (videoSize.height - mark.origin.y - CGFloat(mark.image.height)) * scale)
    }

    /// The transcript around the playhead: the line being said, lit, between dimmed neighbours.
    private var audioCard: some View {
        let lines = model.captionLines
        let current = lines.lastIndex { $0.start <= model.currentTime } ?? 0
        let shown = lines.isEmpty ? [] : Array(lines.indices.filter { $0 >= current - 1 && $0 <= current + 3 })
        return VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: model.isPlaying)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(shown, id: \.self) { index in
                    Text(lines[index].text)
                        .font(index == current ? .title2.weight(.bold) : .title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(index == current ? 1 : (index < current ? 0.3 : 0.5)))
                        // The current line always shows in full; the others give way when space is short.
                        .fixedSize(horizontal: false, vertical: index == current)
                        .lineLimit(index == current ? nil : 1)
                        .layoutPriority(index == current ? 1 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: current)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // On short screens the lines below the current one are cut off rather than spilling over the controls.
        .clipped()
        .ypGlassEffect(cornerRadius: 24)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlay() }
    }

    // MARK: Transport

    /// Play from the start, play or pause, and the preview speed. Moving through the recording
    /// happens on the timeline below.
    private var transport: some View {
        HStack(spacing: 0) {
            Text(Duration.seconds(model.currentTime), format: .time(pattern: .minuteSecond))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 22) {
                Button { model.playFromStart() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play from the Start")

                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 56, height: 56)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Menu {
                    Picker("Speed", selection: Binding(get: { model.playbackRate }, set: { model.setPlaybackRate($0) })) {
                        ForEach(RecordingEditorModel.playbackRates, id: \.self) { rate in
                            Text(rateLabel(rate)).tag(rate)
                        }
                    }
                    // Flat in the menu: one click picks a speed, without a submenu on the Mac.
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(rateLabel(model.playbackRate))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .frame(width: 44, height: 44)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                #endif
                .accessibilityLabel("Speed")
            }
            Spacer(minLength: 0)
            Text(Duration.seconds(model.length), format: .time(pattern: .minuteSecond))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .disabled(!model.hasItem || model.isRendering)
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
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
                Menu {
                    addMenuItems(at: index + 1)
                } label: {
                    toolLabel("Add After", icon: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.plain)
                // On its own anchor: a menu can't host a popover.
                .background { Color.clear.ypPopoverTip(tip(.addClip), arrowEdge: .bottom, action: handleEditorTip) }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                #endif
                .ypGlassEffect(cornerRadius: 16)
                .disabled(model.isAddingClip)
                .opacity(model.isAddingClip ? 0.4 : 1)
            } else {
                #if os(macOS)
                Text("Click a piece to edit it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("Tap a piece to edit it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .disabled(model.isRendering)
    }

    private func toolButton(_ title: LocalizedStringKey, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolLabel(title, icon: icon)
        }
        .buttonStyle(.plain)
        .ypGlassEffect(cornerRadius: 16)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }

    private func toolLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 68, height: 44)
        .contentShape(Rectangle())
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            deliveryRow
            Toggle(isOn: Binding(get: { model.recording.removePauses }, set: {
                if $0 { removePausesTip.done() }
                model.setRemovePauses($0)
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove Pauses")
                    Text("Cuts the silences between your sentences.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.accentColor)
            .ypPopoverTip(tip(.removePauses), arrowEdge: .bottom, action: handleEditorTip)

            #if os(macOS)
            // Beside the video the column can be narrow: the controls go under the label then.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    captionLabel
                    Spacer()
                    captionControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    captionLabel
                    HStack(spacing: 10) { captionControls }
                }
            }
            #else
            HStack(spacing: 10) {
                captionLabel
                Spacer()
                captionControls
            }
            #endif
            captionStatus
        }
        .padding(14)
        .ypGlassEffect(cornerRadius: 20)
        .disabled(model.isRendering)
    }

    /// Pace, filler words and long pauses at a glance; the full report is part of Pro.
    @ViewBuilder
    private var deliveryRow: some View {
        if let report = model.deliveryReport {
            Button {
                deliveryTip.done()
                if model.hasPro { showingDelivery = true } else { onUpgrade(.deliveryReport) }
            } label: {
                HStack(spacing: 10) {
                    Text("Delivery")
                        .fixedSize()
                    Spacer(minLength: 8)
                    // The pace's unit goes first when the row is short of room.
                    ViewThatFits(in: .horizontal) {
                        deliveryChips(report, showsUnit: true)
                        deliveryChips(report, showsUnit: false)
                    }
                    .labelStyle(DeliveryChipLabelStyle())
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Image(systemName: model.hasPro ? "chevron.right" : "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Delivery")
            .accessibilityValue(deliverySummary(report))
            .accessibilityHint(model.hasPro ? "Opens the delivery report" : "Part of yPrompt Pro")
            .background { Color.clear.ypPopoverTip(tip(.delivery), arrowEdge: .bottom, action: handleEditorTip) }
            .popover(isPresented: $showingDelivery, arrowEdge: .bottom) {
                DeliveryReportView(model: model)
            }
            .transition(.opacity)
        }
    }

    private func deliveryChips(_ report: DeliveryReport, showsUnit: Bool) -> some View {
        HStack(spacing: 12) {
            if let pace = report.wordsPerMinute {
                Label {
                    if showsUnit {
                        Text("\(Int(pace.rounded())) wpm")
                    } else {
                        Text(Int(pace.rounded()), format: .number)
                    }
                } icon: {
                    Image(systemName: "speedometer")
                }
            }
            Label { Text(report.fillers.count, format: .number) } icon: { Image(systemName: "text.bubble") }
            Label { Text(report.pauses.count, format: .number) } icon: { Image(systemName: "pause.circle") }
        }
        .fixedSize()
    }

    private func deliverySummary(_ report: DeliveryReport) -> Text {
        let pace = report.wordsPerMinute.map { Text("Pace: \(Int($0.rounded())) words per minute.") + Text(verbatim: " ") }
        return (pace ?? Text(verbatim: ""))
            + Text("Filler words: \(report.fillers.count).") + Text(verbatim: " ")
            + Text("Long pauses: \(report.pauses.count).")
    }

    private var captionLabel: some View {
        Text(model.isVideo ? "Captions" : "Transcript")
            .fixedSize()
    }

    @ViewBuilder
    private var captionControls: some View {
        if model.isVideo {
            Picker("Captions", selection: Binding(get: { model.recording.captionStyle },
                                                  set: {
                                                      if $0 != .off { captionsTip.done() }
                                                      model.setCaptionStyle($0)
                                                  })) {
                ForEach(CaptionStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .ypPopoverTip(tip(.captions), arrowEdge: .bottom, action: handleEditorTip)
            if model.recording.captionStyle != .off {
                // Font, size, position, colors and background.
                Button {
                    captionStyleTip.done()
                    showingCaptionStyle = true
                } label: {
                    Image(systemName: "textformat")
                        .font(.title3)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Caption Style")
                #endif
                .accessibilityLabel("Caption Style")
                .background { Color.clear.ypPopoverTip(tip(.captionStyle), arrowEdge: .bottom, action: handleEditorTip) }
                .popover(isPresented: $showingCaptionStyle, arrowEdge: .bottom) {
                    CaptionStyleView(model: model)
                }
            }
        }
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
                    #if os(macOS)
                    let settings = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
                    #else
                    let settings = UIApplication.openSettingsURLString
                    #endif
                    if let url = URL(string: settings) { openURL(url) }
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
            Label(savedLabel, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: model.renderState == .saved)
                .frame(maxWidth: .infinity, minHeight: 50)
                .transition(.opacity)
        case .idle, .failed:
            HStack(spacing: 12) {
                if canRecordMore {
                    Button { onRecordMore(model.pickup(after: model.recording.pieces.count - 1)) } label: {
                        // Just the icon when there's no room for the words, as beside the video in landscape.
                        ViewThatFits(in: .horizontal) {
                            Label("Record More", systemImage: model.isVideo ? "video.badge.plus" : "mic.badge.plus")
                                .lineLimit(1)
                                .fixedSize()
                            Image(systemName: model.isVideo ? "video.badge.plus" : "mic.badge.plus")
                        }
                        .frame(minHeight: 36)
                        .padding(.horizontal, 4)
                    }
                    .ypGlassButtonStyle()
                    .accessibilityLabel("Record More")
                }
                #if os(macOS)
                // Video or audio, the Mac saves a file where you choose.
                Button { model.save() } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .ypGlassProminentButtonStyle()
                .disabled(!model.hasItem)
                .keyboardShortcut("s", modifiers: .command)
                .ypPopoverTip(tip(.saveWithoutMark), arrowEdge: .bottom, action: handleEditorTip)
                #else
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
                    .ypPopoverTip(tip(.saveWithoutMark), arrowEdge: .bottom, action: handleEditorTip)
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
                #endif
            }
        }
    }

    private var savedLabel: LocalizedStringKey {
        #if os(macOS)
        "Saved"
        #else
        "Saved to Photos"
        #endif
    }

    #if os(macOS)
    /// Keyboard shortcuts for the editor, as invisible buttons so they work wherever focus is.
    private var editorShortcuts: some View {
        Group {
            Button("Play or Pause") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Split") { if model.canSplit { model.split() } }
                .keyboardShortcut("b", modifiers: .command)
            Button("Delete Piece") { deleteSelectedPiece() }
                .keyboardShortcut(.delete, modifiers: [])
            Button("Undo") { if model.canUndo { model.undo() } }
                .keyboardShortcut("z", modifiers: .command)
            Button("Back One Second") { model.seek(to: max(0, model.currentTime - 1)) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward One Second") { model.seek(to: min(model.length, model.currentTime + 1)) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Zoom In") { model.zoomTimeline(by: 1.5) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { model.zoomTimeline(by: 1 / 1.5) }
                .keyboardShortcut("-", modifiers: .command)
        }
        .disabled(model.isRendering || !model.hasItem)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func deleteSelectedPiece() {
        guard let index = model.selectedIndex else { return }
        if model.recording.pieces.count > 1 {
            model.deletePiece(model.recording.pieces[index].id)
        } else {
            onDeleteRecording()
        }
    }
    #endif
}

// MARK: - Player and overlays

#if os(macOS)
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {}

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

/// Opens the macOS share menu from the view it sits behind once there's something to share.
private struct SharePickerAnchor: NSViewRepresentable {
    @Binding var items: RecordingEditorModel.ShareItems?
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        guard let items, context.coordinator.shownID != items.id else { return }
        context.coordinator.shownID = items.id
        let picker = NSSharingServicePicker(items: items.urls)
        picker.delegate = context.coordinator
        DispatchQueue.main.async {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var parent: SharePickerAnchor
        var shownID: UUID?

        init(parent: SharePickerAnchor) { self.parent = parent }

        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            // Called when something was chosen and when the menu was dismissed.
            Task { @MainActor in
                parent.items = nil
                parent.onDismiss()
            }
        }
    }
}
#else
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
#endif

/// The captions over the playing recording, drawn by the renderer the saved video uses.
private struct CaptionOverlay: View {
    let renderer: CaptionRenderer
    let videoSize: CGSize
    let time: () -> Double

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                if videoSize.width > 0, let caption = renderer.image(at: time()) {
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

/// An icon and a number, close together, for the Delivery row.
private struct DeliveryChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

#if os(iOS)
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
#endif
