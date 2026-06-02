//
//  FloatingTeleprompterView.swift
//  yprompt
//

#if os(macOS)
import SwiftUI

struct FloatingTeleprompterView: View {
    @ObservedObject private var manager: FloatingTeleprompterManager
    @ObservedObject private var viewModel: TeleprompterViewModel
    @Environment(\.fontResolutionContext) private var fontContext
    @State private var isHovering = false
    @State private var showUpgradeAlert = false
    @State private var floatingTimedEnabled = false
    @State private var floatingTimedMinutes: Int = 3

    init() {
        let mgr = FloatingTeleprompterManager.shared
        _manager = ObservedObject(wrappedValue: mgr)
        _viewModel = ObservedObject(wrappedValue: mgr.viewModel)
    }

    private var customization: TextCustomization {
        manager.currentScript?.customization ?? TextCustomization()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .opacity(manager.blurAmount)

            RoundedRectangle(cornerRadius: 18)
                .fill(.black.opacity(manager.backgroundOpacity))

            GeometryReader { geo in
                scrollableText
                    .frame(width: geo.size.width)
                    .clipped()
                    .onAppear { viewModel.screenHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in viewModel.screenHeight = h }
            }

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(manager.backgroundOpacity), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 22)
                .allowsHitTesting(false)
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(manager.backgroundOpacity)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 22)
                .allowsHitTesting(false)
            }

            if isHovering || manager.showQueueBanner {
                controlsBar
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .onChange(of: manager.currentScript?.id) { viewModel.resetToTop() }
        .alert("Premium Feature", isPresented: $showUpgradeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Voice Scroll is available with YPrompt Premium. Open the main app to upgrade.")
        }
        .alert("Microphone Access Required", isPresented: $viewModel.micPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Voice Scroll needs microphone access to detect when you are speaking.")
        }
    }

    // MARK: - Scrolling text

    private func normalizedText(from input: AttributedString) -> AttributedString {
        var result = input
        for run in result.runs {
            guard let font = run.font else { continue }
            let resolved = font.resolve(in: fontContext)
            var scaled = Font.system(size: manager.floatingFontSize)
            if resolved.isBold { scaled = scaled.bold() }
            if resolved.isItalic { scaled = scaled.italic() }
            result[run.range].font = scaled
        }
        return result
    }

    private var scrollableText: some View {
        let isEmpty = (manager.currentScript?.content ?? "").isEmpty
        let raw = isEmpty
            ? AttributedString("[ No script — pick one from the menu bar ]")
            : (manager.currentScript?.attributedContent ?? AttributedString())
        let displayText = normalizedText(from: raw)
        return Text(displayText)
            .font(.system(size: manager.floatingFontSize))
            .foregroundStyle(.white)
            .multilineTextAlignment(customization.textAlignmentIndex.textAlignment)
            .lineSpacing(4)
            .padding(.horizontal, manager.horizontalPadding)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: customization.textAlignmentIndex.frameAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { viewModel.contentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in viewModel.contentHeight = h }
                }
            )
            .offset(y: -viewModel.contentOffset)
    }

    // MARK: - Helpers

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func updateFloatingTimedDuration() {
        let total = TimeInterval(floatingTimedMinutes * 60)
        viewModel.timedDuration = total > 0 ? total : 180
    }

    // MARK: - Hover controls

    private var controlsBar: some View {
        VStack(spacing: 6) {
            // Queue "Up Next" banner
            if manager.showQueueBanner, let next = manager.nextInQueue {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Up Next")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(next.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Auto in \(manager.queueCountdown)s")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                    Button("Play Now") { manager.advanceQueue() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    Button { manager.cancelQueueBanner() } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Cancel queue advance")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Row 1 — playback + voice scroll
            HStack(spacing: 12) {
                Button { viewModel.resetToTop() } label: {
                    Image(systemName: "backward.end.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("Reset to top")

                Button { viewModel.togglePlayPause() } label: {
                    Image(
                        systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                    )
                    .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(viewModel.isPlaying ? "Pause" : "Play")

                Picker("", selection: Binding(
                    get: { floatingTimedEnabled ? 1 : 0 },
                    set: { newVal in
                        if newVal == 1 {
                            guard manager.isPremium else { showUpgradeAlert = true; return }
                            floatingTimedEnabled = true
                            updateFloatingTimedDuration()
                        } else {
                            floatingTimedEnabled = false
                            viewModel.timedDuration = nil
                        }
                    }
                )) {
                    Image(systemName: "hare.fill").tag(0)
                    Image(systemName: "timer").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 60)

                if floatingTimedEnabled {
                    if viewModel.isPlaying && viewModel.timedDuration != nil {
                        Text(timeString(viewModel.remainingTime))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 40)
                    } else {
                        HStack(spacing: 2) {
                            Button {
                                if floatingTimedMinutes > 0 { floatingTimedMinutes -= 1; updateFloatingTimedDuration() }
                            } label: { Image(systemName: "minus").font(.caption2) }
                            .buttonStyle(.plain)
                            Text("\(floatingTimedMinutes)m")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(minWidth: 24)
                            Button {
                                floatingTimedMinutes = min(59, floatingTimedMinutes + 1)
                                updateFloatingTimedDuration()
                            } label: { Image(systemName: "plus").font(.caption2) }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    MusicSlider(
                        value: $viewModel.scrollSpeed,
                        range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                        step: 0.1
                    )
                    .frame(width: 80)
                    Text(String(format: "%.1fx", viewModel.scrollSpeed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 28)
                }

                // Voice scroll toggle (premium)
                Button {
                    if manager.isPremium {
                        Task { await viewModel.toggleVoiceScroll() }
                    } else {
                        showUpgradeAlert = true
                    }
                } label: {
                    Image(systemName: viewModel.voiceScrollEnabled ? "mic.fill" : "mic")
                        .font(.caption)
                        .foregroundStyle(viewModel.voiceScrollEnabled ? Color.green : Color.white)
                }
                .buttonStyle(.plain)
                .help(viewModel.voiceScrollEnabled ? "Disable Voice Scroll" : "Voice Scroll (Premium)")

                if viewModel.voiceScrollEnabled {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { viewModel.showVoiceMeter.toggle() }
                    } label: {
                        Image(systemName: viewModel.showVoiceMeter ? "waveform" : "waveform.slash")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(viewModel.showVoiceMeter ? 1.0 : 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.showVoiceMeter ? "Hide level meter" : "Show level meter")
                }

                Spacer()

                Button { FloatingTeleprompterManager.shared.hide() } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .help("Close")
            }

            // Row 2 — appearance
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .help("Background opacity")

                MusicSlider(value: $manager.backgroundOpacity, range: 0.15...1.0, step: 0.05)

                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1, height: 10)

                Image(systemName: "camera.filters")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .help("Background blur")

                MusicSlider(value: $manager.blurAmount, range: 0.0...1.0, step: 0.05)
            }

            // Row 3 — voice level meter (only when voice scroll is enabled and meter is visible)
            if viewModel.voiceScrollEnabled && viewModel.showVoiceMeter {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .help("Drag yellow marker to set speaking threshold")

                    VoiceLevelMeterView(service: viewModel.voiceScrollService)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { viewModel.showVoiceMeter = false }
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Hide level meter")
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.voiceScrollEnabled && viewModel.showVoiceMeter)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
#endif
