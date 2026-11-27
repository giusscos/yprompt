//
//  TimelineStripView.swift
//  yprompt
//

#if os(iOS) || os(macOS)
import AVFoundation
import CoreMedia
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The recording's pieces laid out in time, scrolling under a playhead that stays in the middle.
/// Drag along it (or swipe on a trackpad) to move through the recording, pinch to zoom, tap a
/// piece to select it and jump there, drag a selected piece's ends to trim it, and hold and drag
/// a piece to move it: while it's lifted the timeline shrinks to show every piece, and the
/// others make room where it would land. A plus at the end adds more.
struct TimelineStripView<AddMenu: View>: View {
    @Bindable var model: RecordingEditorModel
    @ViewBuilder let addMenu: () -> AddMenu

    @State private var trimDrag: TrimDrag?
    /// The piece being moved, and where the finger is along the strip once it starts dragging.
    @State private var moving: (id: UUID, x: CGFloat?)?
    /// Resets by itself if the system cancels the drag, so a piece is never left lifted.
    @GestureState private var isHoldingPiece = false
    /// The content position under the playhead when a scrubbing drag began.
    @State private var scrubAnchor: CGFloat?
    /// A scrub is under way: a drag, the glide after it, or trackpad scrolling.
    @State private var isScrubbing = false
    @State private var glide: Task<Void, Never>?
    @State private var zoomAtPinchStart: Double?
    @State private var stripWidth: CGFloat = 0
    #if os(macOS)
    @State private var isHovering = false
    @State private var wheelMonitor: Any?
    @State private var wheelEnd: Task<Void, Never>?
    #endif

    private struct TrimDrag {
        let id: UUID
        let isStart: Bool
        var seconds: Double
        let secondsPerPoint: Double
        /// Where the content sat when the drag began. It holds still while trimming, so the
        /// edge being dragged stays under the finger.
        let offset: CGFloat
    }

    /// A piece being moved: where it was, where it would land, and how far it has gone.
    private struct Move {
        let id: UUID
        let from: Int
        let to: Int
        let translation: CGFloat
        /// How far the other pieces step aside: the moved piece's width and a gap.
        let gap: CGFloat
    }

    static var height: CGFloat { 78 }
    private let spacing: CGFloat = 4
    private let tileHeight: CGFloat = 58
    private let rulerHeight: CGFloat = 20
    private let minTileWidth: CGFloat = 28
    /// Room either side of the pieces while one is being moved.
    private let moveMargin: CGFloat = 12
    private let moveAnimation = Animation.snappy(duration: 0.3)
    private let glideAnimation = Animation.snappy(duration: 0.35)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // Redrawn every frame while playing, so the pieces slide smoothly under the playhead.
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !model.isPlaying)) { _ in
                let layout = makeLayout(width: width)
                strip(layout: layout, width: width, offset: contentOffset(layout, width: width))
            }
            .onAppear { stripWidth = width }
            .onChange(of: width) { _, newWidth in stripWidth = newWidth }
        }
        .frame(height: Self.height)
        .onChange(of: isHoldingPiece) { _, holding in
            if !holding && moving != nil { withAnimation(moveAnimation) { moving = nil } }
        }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active: isHovering = true
            case .ended: isHovering = false
            }
        }
        .onAppear(perform: installWheelMonitor)
        .onDisappear {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }
        #endif
    }

    // MARK: Layout

    /// Where each piece sits: as long as its share of time while scrolling, or squeezed so every
    /// piece fits while one is being moved.
    private func makeLayout(width: CGFloat) -> TimelineLayout {
        let pieces = model.recording.pieces
        let spans = pieces.map { model.editList.span(of: $0.id) }
        let lengths = pieces.indices.map { spans[$0]?.length ?? pieces[$0].length }
        var widths: [CGFloat]
        var growth: CGFloat = 0
        let pointsPerSecond: CGFloat
        if moving != nil {
            let available = max(0, width - moveMargin * 2 - spacing * CGFloat(max(0, pieces.count - 1)))
            let sum = max(lengths.reduce(0, +), 0.01)
            let raw = lengths.map { max(minTileWidth, available * CGFloat($0 / sum)) }
            let scale = min(1, available / max(raw.reduce(0, +), 1))
            widths = raw.map { $0 * scale }
            pointsPerSecond = available / CGFloat(sum)
        } else {
            pointsPerSecond = self.pointsPerSecond(width: width)
            widths = lengths.map { max(minTileWidth, CGFloat($0) * pointsPerSecond) }
            if let drag = trimDrag, let index = pieces.firstIndex(where: { $0.id == drag.id }) {
                let trimmed = max(0.3, lengths[index] + (drag.isStart ? -drag.seconds : drag.seconds))
                let newWidth = max(minTileWidth, CGFloat(trimmed) * pointsPerSecond)
                growth = newWidth - widths[index]
                widths[index] = newWidth
            }
        }
        var lefts: [CGFloat] = []
        var x: CGFloat = 0
        for tileWidth in widths {
            lefts.append(x)
            x += tileWidth + spacing
        }
        return TimelineLayout(pieces: pieces, spans: spans, widths: widths, lefts: lefts, spacing: spacing,
                              length: model.length, pointsPerSecond: pointsPerSecond, trimGrowth: growth)
    }

    /// About twelve seconds across the strip at zoom 1, and never less than the whole recording.
    private func pointsPerSecond(width: CGFloat) -> CGFloat {
        let fit = width / CGFloat(max(model.length, 0.5))
        return max(fit, width / 12 * CGFloat(model.timelineZoom))
    }

    /// Where the content's left edge sits along the strip.
    private func contentOffset(_ layout: TimelineLayout, width: CGFloat) -> CGFloat {
        if moving != nil { return moveMargin }
        if let trimDrag { return trimDrag.offset - (trimDrag.isStart ? layout.trimGrowth : 0) }
        return width / 2 - layout.x(of: displayTime)
    }

    /// The player's own clock while playing, so the strip moves smoothly; the playhead otherwise.
    private var displayTime: Double {
        guard model.isPlaying else { return model.currentTime }
        let seconds = model.player.currentTime().seconds
        return seconds.isFinite ? min(max(0, seconds), model.length) : model.currentTime
    }

    /// The part of the content worth drawing: what's in view and a strip's width either side, in
    /// steps of a strip's width, so frames aren't laid out again on every step of a scroll.
    private func drawnRange(offset: CGFloat, width: CGFloat) -> ClosedRange<CGFloat> {
        let step = max(width, 100)
        let start = (floor(-offset / step) - 1) * step
        return start...(start + step * 3)
    }

    // MARK: Strip

    private func strip(layout: TimelineLayout, width: CGFloat, offset: CGFloat) -> some View {
        let move = plannedMove(layout)
        let drawn = drawnRange(offset: offset, width: width)
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if move == nil {
                    // Wider than the pieces, so the first and last labels aren't cut in half.
                    TimelineRuler(ticks: ticks(layout, in: drawn), inset: 30)
                        .equatable()
                        .frame(width: max(1, layout.contentWidth) + 60, height: rulerHeight)
                        .offset(x: -30)
                }
                HStack(spacing: spacing) {
                    ForEach(Array(layout.pieces.enumerated()), id: \.element.id) { index, piece in
                        tile(piece, index: index, layout: layout, move: move, drawn: drawn, offset: offset)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                    if moving == nil {
                        addButton
                    }
                }
                .padding(.top, rulerHeight)
                .animation(moveAnimation, value: layout.pieces)
            }
            .fixedSize()
            .offset(x: offset)

            if move == nil && trimDrag == nil {
                playhead(width: width)
            }
            if model.isAddingClip {
                addingBadge
                    .frame(width: width, height: Self.height)
            }
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .mask(edgeFade)
        // Pieces scrolled out of view stay hidden from touches too, beside the video on the Mac.
        .contentShape(Rectangle())
        .simultaneousGesture(scrubGesture(layout), including: model.hasItem ? .all : .subviews)
        .simultaneousGesture(zoomGesture)
        .coordinateSpace(.named("strip"))
        .sensoryFeedback(.impact(weight: .medium), trigger: move?.id) { _, new in new != nil }
        .sensoryFeedback(.selection, trigger: move?.to) { old, new in old != nil && new != nil }
    }

    /// The ends fade out, so pieces slide in and out rather than stop at a hard edge.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
        }
    }

    private var addButton: some View {
        Menu {
            addMenu()
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: tileHeight)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add")
        #endif
        .disabled(model.isAddingClip || model.isRendering)
        .accessibilityLabel("Add")
    }

    private var addingBadge: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Adding the clip…")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.7), in: Capsule())
        .allowsHitTesting(false)
    }

    // MARK: Ruler

    /// A label every few seconds, with a dot halfway between, spaced to stay readable at any zoom.
    private func ticks(_ layout: TimelineLayout, in drawn: ClosedRange<CGFloat>) -> [TimelineTick] {
        guard layout.length > 0, layout.pointsPerSecond > 0, !layout.pieces.isEmpty else { return [] }
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first { $0 * Double(layout.pointsPerSecond) >= 56 } ?? 600
        let half = step / 2
        var index = Int(max(0, layout.time(at: drawn.lowerBound)) / half)
        var ticks: [TimelineTick] = []
        while ticks.count < 400 {
            let time = Double(index) * half
            guard time <= layout.length + 0.001 else { break }
            let x = layout.x(of: time)
            guard x <= drawn.upperBound else { break }
            if x >= drawn.lowerBound {
                let label = index.isMultiple(of: 2)
                    ? Duration.seconds(time).formatted(.time(pattern: .minuteSecond))
                    : nil
                ticks.append(TimelineTick(x: x, label: label))
            }
            index += 1
        }
        return ticks
    }

    // MARK: Moving a piece

    /// The piece being moved passes another once its leading edge crosses that piece's middle:
    /// its right edge going right, its left edge going left. Its own middle wouldn't do: a
    /// piece wider than the first or last can't get its middle past theirs, so it could never
    /// reach either end. The middles are measured where the pieces sit before the move, so
    /// they don't shift under the finger as the others step aside.
    private func plannedMove(_ layout: TimelineLayout) -> Move? {
        guard let moving, let from = layout.pieces.firstIndex(where: { $0.id == moving.id }) else { return nil }
        let lefts = layout.lefts, widths = layout.widths
        // Centered under the finger once it moves; where it sits until then.
        let wanted = moving.x.map { $0 - moveMargin - widths[from] / 2 } ?? lefts[from]
        let left = min(max(wanted, 0), max(0, layout.contentWidth - widths[from]))
        let right = left + widths[from]
        let to = layout.pieces.indices.filter { index in
            guard index != from else { return false }
            let middle = lefts[index] + widths[index] / 2
            // Counts the pieces that end up before the moved one.
            return index < from ? left >= middle : right > middle
        }.count
        return Move(id: moving.id, from: from, to: to, translation: left - lefts[from], gap: widths[from] + spacing)
    }

    /// The moved piece follows the finger; those between where it was and where it would
    /// land step aside to make room.
    private func moveOffset(at index: Int, in move: Move?) -> CGFloat {
        guard let move else { return 0 }
        if index == move.from { return move.translation }
        if move.from < index && index <= move.to { return -move.gap }
        if move.to <= index && index < move.from { return move.gap }
        return 0
    }

    private func finishMove(_ id: UUID) {
        let move = plannedMove(makeLayout(width: stripWidth))
        withAnimation(moveAnimation) {
            if let move, move.to != move.from { model.move(id, to: move.to) }
            moving = nil
        }
    }

    /// Hold a piece, then drag it along the strip. Measured in the strip's space, so the piece
    /// moving under the finger doesn't throw off the distance.
    private func moveGesture(_ piece: Piece) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")))
            .updating($isHoldingPiece) { value, holding, _ in
                if case .second(true, _) = value { holding = true }
            }
            .onChanged { value in
                // A drag that's already scrolling the strip doesn't turn into a move.
                guard case .second(true, let drag) = value, scrubAnchor == nil, trimDrag == nil else { return }
                if moving == nil {
                    stopScrubbing()
                    withAnimation(moveAnimation) { moving = (piece.id, drag?.location.x) }
                } else {
                    moving = (piece.id, drag?.location.x ?? moving?.x)
                }
            }
            .onEnded { value in
                guard case .second(true, _) = value else { return }
                finishMove(piece.id)
            }
    }

    // MARK: Scrubbing

    /// Drag the strip to move through the recording; a flick carries on and slows down.
    private func scrubGesture(_ layout: TimelineLayout) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("strip"))
            .onChanged { value in
                guard trimDrag == nil, moving == nil, zoomAtPinchStart == nil else { return }
                if scrubAnchor == nil {
                    guard !isHoldingPiece else { return }
                    cancelGlide()
                    openScrub()
                    scrubAnchor = layout.x(of: model.currentTime)
                }
                guard let anchor = scrubAnchor else { return }
                model.scrub(to: layout.time(at: anchor - value.translation.width))
            }
            .onEnded { value in
                guard let anchor = scrubAnchor else { return }
                scrubAnchor = nil
                let flung = value.predictedEndTranslation.width - value.translation.width
                if abs(flung) > 40 {
                    let from = anchor - value.translation.width
                    let distance = min(max(flung, -stripWidth * 2), stripWidth * 2)
                    glide(from: from, to: from - distance)
                } else {
                    closeScrub()
                }
            }
    }

    /// Carries on after a flick, slowing to a stop.
    private func glide(from start: CGFloat, to end: CGFloat) {
        cancelGlide()
        glide = Task { @MainActor in
            let duration = 0.7
            let began = Date.now
            while !Task.isCancelled {
                let progress = min(1, Date.now.timeIntervalSince(began) / duration)
                let eased = 1 - pow(1 - progress, 3)
                let layout = makeLayout(width: stripWidth)
                model.scrub(to: layout.time(at: start + (end - start) * CGFloat(eased)))
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled {
                glide = nil
                closeScrub()
            }
        }
    }

    private func cancelGlide() {
        glide?.cancel()
        glide = nil
    }

    private func openScrub() {
        guard !isScrubbing else { return }
        isScrubbing = true
        model.beginScrub()
    }

    private func closeScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        model.endScrub()
    }

    /// Before a tap, a trim or a move: a glide stops where it is.
    private func stopScrubbing() {
        cancelGlide()
        scrubAnchor = nil
        closeScrub()
    }

    // MARK: Zooming

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let range = model.timelineZoomRange
                if zoomAtPinchStart == nil {
                    zoomAtPinchStart = min(max(model.timelineZoom, range.lowerBound), range.upperBound)
                }
                let zoom = (zoomAtPinchStart ?? 1) * value.magnification
                model.timelineZoom = min(max(zoom, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in zoomAtPinchStart = nil }
    }

    #if os(macOS)
    /// Two-finger swipes on a trackpad, or Shift and the mouse wheel, move through the recording
    /// while the pointer is over the strip. Up and down still scroll the column.
    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleWheel(event) ? nil : event
        }
    }

    private func handleWheel(_ event: NSEvent) -> Bool {
        guard isHovering, trimDrag == nil, moving == nil, model.hasItem, !model.isRendering else { return false }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard dx != 0, abs(dx) > abs(dy) else { return false }
        cancelGlide()
        openScrub()
        let layout = makeLayout(width: stripWidth)
        let points = event.hasPreciseScrollingDeltas ? dx : dx * 10
        model.scrub(to: layout.time(at: layout.x(of: model.currentTime) - points))
        wheelEnd?.cancel()
        wheelEnd = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            closeScrub()
        }
        return true
    }
    #endif

    // MARK: Tiles

    private func tile(_ piece: Piece, index: Int, layout: TimelineLayout, move: Move?,
                      drawn: ClosedRange<CGFloat>, offset: CGFloat) -> some View {
        let width = layout.widths[index]
        let isSelected = model.selectedPieceID == piece.id
        let isMoving = move?.id == piece.id
        let shift = moveOffset(at: index, in: move)
        let visible = (drawn.lowerBound - layout.lefts[index])...(drawn.upperBound - layout.lefts[index])
        let select = { (location: CGPoint) in
            stopScrubbing()
            withAnimation(glideAnimation) {
                model.select(piece.id, at: Double(location.x / max(width, 1)))
            }
        }
        return ZStack {
            tileContent(piece, span: layout.spans[index], width: width, visible: visible)
                .frame(width: width, height: tileHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                // On the picture, under the trim handles, so holding a handle still trims. The tap
                // sits with the hold: a tap further out would wait on it and never fire.
                .onTapGesture(coordinateSpace: .local, perform: select)
                .gesture(moveGesture(piece), including: layout.pieces.count > 1 ? .all : .subviews)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .opacity(isSelected ? 1 : 0)
            if isSelected && move == nil {
                HStack {
                    handle(piece, isStart: true, width: width, offset: offset)
                    Spacer(minLength: 0)
                    handle(piece, isStart: false, width: width, offset: offset)
                }
                .transition(.opacity)
            }
            if let drag = trimDrag, drag.id == piece.id {
                Text(Duration.seconds(max(0.3, piece.length + (drag.isStart ? -drag.seconds : drag.seconds))),
                     format: .time(pattern: .minuteSecond))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(4)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        .frame(width: width, height: tileHeight)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .scaleEffect(isMoving ? 1.08 : 1)
        .shadow(color: .black.opacity(isMoving ? 0.5 : 0), radius: 8, y: 4)
        .animation(.snappy(duration: 0.2), value: isMoving)
        .offset(x: shift)
        // The moved piece tracks the finger exactly; the others glide. On release the moved
        // piece glides too, from under the finger into its new place.
        .animation(isMoving ? nil : moveAnimation, value: shift)
        .zIndex(isMoving ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local, perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Piece \(index + 1)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // VoiceOver: swipe up to move the piece later, down to move it earlier.
        .accessibilityAdjustableAction { direction in
            let to = direction == .increment ? index + 1 : index - 1
            guard layout.pieces.indices.contains(to) else { return }
            withAnimation(moveAnimation) { model.move(piece.id, to: to) }
            AccessibilityNotification.Announcement(AttributedString(localized: "Piece \(to + 1)")).post()
        }
    }

    @ViewBuilder
    private func tileContent(_ piece: Piece, span: PieceSpan?, width: CGFloat, visible: ClosedRange<CGFloat>) -> some View {
        if model.isVideo {
            filmstrip(piece, span: span, width: width, visible: visible)
        } else {
            TimelineWaveform(levels: levels(for: piece), visible: visible)
                .equatable()
                .background(Color.accentColor.opacity(0.25))
        }
    }

    /// Frames along the piece, each at the moment it sits over, as many as fit.
    private func filmstrip(_ piece: Piece, span: PieceSpan?, width: CGFloat, visible: ClosedRange<CGFloat>) -> some View {
        let strip = model.filmstrips[piece.file]
        let turns = ((model.recording.quarterTurns % 4) + 4) % 4
        let aspect = strip.map { turns.isMultiple(of: 2) ? $0.aspect : 1 / max($0.aspect, 0.01) } ?? 9.0 / 16.0
        let slotWidth = max(16, (tileHeight * aspect).rounded())
        let count = max(1, Int((width / slotWidth).rounded(.up)))
        let first = max(0, Int(floor(visible.lowerBound / slotWidth)))
        let last = min(count - 1, Int(ceil(visible.upperBound / slotWidth)))
        return ZStack(alignment: .leading) {
            Color.white.opacity(0.12)
            if let strip, first <= last {
                ForEach(first...last, id: \.self) { slot in
                    let fraction = min(1, (CGFloat(slot) + 0.5) * slotWidth / max(width, 1))
                    if let frame = strip.frame(at: sourceTime(piece, span: span, fraction: Double(fraction))) {
                        frameImage(frame, turns: turns, slotWidth: slotWidth)
                            .offset(x: CGFloat(slot) * slotWidth)
                    }
                }
            }
        }
        .frame(width: width, height: tileHeight, alignment: .leading)
    }

    private func frameImage(_ frame: CGImage, turns: Int, slotWidth: CGFloat) -> some View {
        let sideways = !turns.isMultiple(of: 2)
        return Image(decorative: frame, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: sideways ? tileHeight : slotWidth, height: sideways ? slotWidth : tileHeight)
            .rotationEffect(.degrees(Double(turns) * 90))
            .frame(width: slotWidth, height: tileHeight)
            .clipped()
    }

    /// The moment of the source shown at a point along a piece, skipping what Remove Pauses cut.
    private func sourceTime(_ piece: Piece, span: PieceSpan?, fraction: Double) -> Double {
        guard let span, let location = model.editList.location(at: span.start + span.length * fraction),
              location.pieceID == piece.id else { return piece.start + piece.length * fraction }
        return location.source
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

    // MARK: Trimming

    /// Drag outward to bring back cut material, inward to cut more. The piece resizes as you drag.
    private func handle(_ piece: Piece, isStart: Bool, width: CGFloat, offset: CGFloat) -> some View {
        Capsule()
            .fill(Color.yellow)
            .frame(width: 8, height: 34)
            .padding(.horizontal, 2)
            .frame(width: 22, height: tileHeight)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("strip"))
                    .onChanged { value in
                        if trimDrag == nil {
                            stopScrubbing()
                            trimDrag = TrimDrag(id: piece.id, isStart: isStart, seconds: 0,
                                                secondsPerPoint: piece.length / Double(max(width, 1)), offset: offset)
                        }
                        guard var drag = trimDrag, drag.id == piece.id else { return }
                        drag.seconds = clampedTrim(Double(value.translation.width) * drag.secondsPerPoint,
                                                   piece: piece, isStart: isStart)
                        trimDrag = drag
                    }
                    .onEnded { _ in
                        guard let drag = trimDrag, drag.id == piece.id else { return }
                        withAnimation(glideAnimation) {
                            if isStart {
                                model.trim(piece.id, start: piece.start + drag.seconds, end: piece.end)
                            } else {
                                model.trim(piece.id, start: piece.start, end: piece.end + drag.seconds)
                            }
                            trimDrag = nil
                        }
                    }
            )
            .accessibilityLabel(isStart ? "Trim start" : "Trim end")
    }

    /// As far as the source goes, and never shorter than a third of a second.
    private func clampedTrim(_ seconds: Double, piece: Piece, isStart: Bool) -> Double {
        if isStart {
            return min(max(seconds, -piece.start), piece.length - 0.3)
        }
        let source = model.sourceDuration(of: piece.file)
        return min(max(seconds, -(piece.length - 0.3)), max(0, source - piece.end))
    }

    // MARK: Playhead

    /// A line through the middle of the strip; the pieces move under it.
    private func playhead(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: tileHeight + 4)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .frame(width: 44)
        .offset(x: width / 2 - 22, y: rulerHeight - 8)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue(Text(Duration.seconds(model.currentTime), format: .time(pattern: .minuteSecond)))
        .accessibilityAdjustableAction { direction in
            model.seek(to: model.currentTime + (direction == .increment ? 1 : -1))
        }
    }
}

// MARK: - Layout

/// Where the pieces sit along the strip, in the content's own coordinates.
private struct TimelineLayout {
    let pieces: [Piece]
    let spans: [PieceSpan?]
    let widths: [CGFloat]
    let lefts: [CGFloat]
    let spacing: CGFloat
    let length: Double
    let pointsPerSecond: CGFloat
    /// How much wider the piece being trimmed is than before the drag.
    let trimGrowth: CGFloat

    var contentWidth: CGFloat { (lefts.last ?? 0) + (widths.last ?? 0) }

    /// Where a moment of the timeline sits along the strip.
    func x(of time: Double) -> CGFloat {
        for index in pieces.indices {
            guard let span = spans[index] else { continue }
            if time < span.end || index == pieces.count - 1 {
                let fraction = span.length > 0 ? min(max((time - span.start) / span.length, 0), 1) : 0
                return lefts[index] + widths[index] * CGFloat(fraction)
            }
        }
        return contentWidth
    }

    /// The moment of the timeline at a point along the strip.
    func time(at x: CGFloat) -> Double {
        for index in pieces.indices {
            guard let span = spans[index] else { continue }
            let right = lefts[index] + widths[index]
            if x <= right + spacing / 2 || index == pieces.count - 1 {
                let fraction = Double(min(max((x - lefts[index]) / max(widths[index], 1), 0), 1))
                return span.start + span.length * fraction
            }
        }
        return length
    }
}

// MARK: - Drawing

private struct TimelineTick: Equatable {
    let x: CGFloat
    /// Nil for the dot between two labels.
    let label: String?
}

private struct TimelineRuler: View, Equatable {
    let ticks: [TimelineTick]
    /// Room before the first piece.
    let inset: CGFloat

    var body: some View {
        Canvas { context, size in
            for tick in ticks {
                let x = tick.x + inset
                if let label = tick.label {
                    let text = Text(label)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                    context.draw(text, at: CGPoint(x: x, y: size.height / 2 - 2), anchor: .center)
                } else {
                    let dot = CGRect(x: x - 1.5, y: size.height / 2 - 3.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.3)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Loudness bars, drawn only where they can be seen.
private struct TimelineWaveform: View, Equatable {
    let levels: [Float]
    /// The part of the piece to draw, in its own coordinates.
    let visible: ClosedRange<CGFloat>

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let bars = max(1, Int(size.width / 3))
            let first = max(0, Int(visible.lowerBound / 3))
            let last = min(bars - 1, Int(visible.upperBound / 3) + 1)
            guard first <= last else { return }
            for bar in first...last {
                let index = min(levels.count - 1, bar * levels.count / bars)
                let level = CGFloat(VoiceScrollService.normalize(levels[index]))
                let height = max(2, level * size.height * 0.9)
                let rect = CGRect(x: CGFloat(bar) * 3, y: (size.height - height) / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.85)))
            }
        }
    }
}
#endif
