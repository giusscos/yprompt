//
//  TeleprompterControls.swift
//  yprompt
//

#if os(iOS)
import SwiftUI

/// In strip order: Auto, the default, opens with a neighbour on each side.
enum TeleprompterMode: String, CaseIterable {
    case tap    = "Tap"
    case auto   = "Auto"
    case voice  = "Voice"
    case timed  = "Timed"

    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

// MARK: - Mode strip

/// Reading modes on a strip that slides under a fixed capsule, like the Camera app:
/// the selected mode always sits in the middle and its neighbours fade towards the edges.
/// Tap a mode, or drag and flick the strip.
struct ReadingModeStrip: View {
    let selection: TeleprompterMode
    /// Colour of the selected mode's label.
    let highlight: Color
    let isLocked: (TeleprompterMode) -> Bool
    let onSelect: (TeleprompterMode) -> Void

    @State private var dragOffset: CGFloat = 0

    private let modes = TeleprompterMode.allCases
    private let itemWidth: CGFloat = 80
    private let height: CGFloat = 36
    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.74)

    private var selectedIndex: Int { modes.firstIndex(of: selection) ?? 0 }

    /// The mode under the capsule right now, which changes during a drag.
    private var focusedIndex: Int {
        let position = CGFloat(selectedIndex) - dragOffset / itemWidth
        return min(max(0, Int(position.rounded())), modes.count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                    item(mode, isFocused: index == focusedIndex)
                }
            }
            .frame(height: height)
            .offset(x: geo.size.width / 2 - (CGFloat(selectedIndex) + 0.5) * itemWidth + dragOffset)
        }
        .frame(height: height)
        .background {
            Color.clear
                .frame(width: itemWidth - 6, height: height - 2)
                .ypGlassEffect(cornerRadius: (height - 2) / 2)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.2),
                    .init(color: .black, location: 0.8),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .sensoryFeedback(.selection, trigger: focusedIndex)
    }

    private func item(_ mode: TeleprompterMode, isFocused: Bool) -> some View {
        Button {
            withAnimation(spring) { onSelect(mode) }
        } label: {
            HStack(spacing: 3) {
                Text(mode.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if isLocked(mode) {
                    Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                }
            }
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(isFocused ? highlight : Color.primary.opacity(0.5))
            .scaleEffect(isFocused ? 1 : 0.88)
            .frame(width: itemWidth, height: height)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == selection ? .isSelected : [])
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                dragOffset = resisted(value.translation.width)
            }
            .onEnded { value in
                let steps = Int((value.predictedEndTranslation.width / itemWidth).rounded())
                let target = min(max(0, selectedIndex - steps), modes.count - 1)
                withAnimation(spring) {
                    dragOffset = 0
                    // A locked mode opens the paywall and the strip springs back.
                    if target != selectedIndex { onSelect(modes[target]) }
                }
            }
    }

    /// Past the first or last mode, the strip follows the finger less and less.
    private func resisted(_ translation: CGFloat) -> CGFloat {
        let upper = CGFloat(selectedIndex) * itemWidth
        let lower = -CGFloat(modes.count - 1 - selectedIndex) * itemWidth
        if translation > upper { return upper + (translation - upper) * 0.3 }
        if translation < lower { return lower + (translation - lower) * 0.3 }
        return translation
    }
}

// MARK: - Small controls

/// A value with minus and plus either side; hold a button to keep going.
struct ReadingValueStepper: View {
    let value: String
    let onDecrease: () -> Void
    let onIncrease: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", action: onDecrease)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: 52)
                .contentTransition(.numericText())
                .animation(.default, value: value)
            stepButton("plus", action: onIncrease)
        }
        .frame(height: 34)
        .ypGlassEffect(cornerRadius: 17)
        .sensoryFeedback(.selection, trigger: value)
    }

    private func stepButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

/// A few bars that move with the microphone level.
struct VoiceLevelBars: View {
    var service: VoiceScrollService

    private let shape: [CGFloat] = [0.55, 0.85, 1, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(shape.indices, id: \.self) { index in
                Capsule()
                    .fill(service.isSpeaking ? Color.green : Color.secondary)
                    .frame(width: 3, height: 4 + 12 * shape[index] * CGFloat(service.normalizedLevel))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: service.normalizedLevel)
        .accessibilityHidden(true)
    }
}

/// A thin line showing how far through the script the reader is, with a tick at each cue point.
struct ReadingProgressLine: View {
    let progress: Double
    let cuePositions: [Double]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: 2.5)
                Capsule()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: max(0, geo.size.width * progress), height: 2.5)
                ForEach(cuePositions.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 8)
                        .offset(x: geo.size.width * cuePositions[index] - 1)
                }
            }
            .frame(height: 8)
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.2), value: progress)
        .accessibilityHidden(true)
    }
}
#endif
