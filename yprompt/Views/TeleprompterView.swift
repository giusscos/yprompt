//
//  TeleprompterView.swift
//  yprompt
//

import SwiftUI
#if os(iOS)
import AVFoundation
#endif

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

#if os(iOS)
private enum TeleprompterMode: String, CaseIterable {
    case auto   = "Auto"
    case tap    = "Tap"
    case voice  = "Voice"
    case camera = "Camera"

    var icon: String {
        switch self {
        case .auto:   return "scroll"
        case .tap:    return "hand.tap.fill"
        case .voice:  return "mic"
        case .camera: return "video"
        }
    }
}
#endif

struct TeleprompterView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var script: Script
    @StateObject private var viewModel = TeleprompterViewModel()
    #if os(iOS)
    @StateObject private var cameraService = CameraRecordingService()
    #endif
    #if !os(watchOS)
    @EnvironmentObject private var storeKit: StoreKitService
    @State private var showingPaywall = false
    #endif
    #if os(iOS)
    @State private var playerDetent: PresentationDetent = .height(420)
    @State private var teleprompterMode: TeleprompterMode = .auto
    @Namespace private var modeNamespace
    #endif

    private var customization: TextCustomization { script.customization }

    #if os(iOS)
    private var contentBackground: Color {
        cameraService.isCameraActive ? .clear : Color(hex: customization.backgroundColorHex)
    }
    #endif

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        scrollingContent(screenSize: geo.size)
                            .clipped()
                            .onAppear {
                                viewModel.screenHeight = geo.size.height
                                viewModel.scrollSpeed = customization.scrollSpeed
                                viewModel.transparency = customization.transparency
                            }
                    }
                    .onTapGesture {
                        if viewModel.isTapToAdvance { viewModel.tapAdvance() }
                    }

                    #if !os(watchOS)
                    Group {
                        if viewModel.voiceScrollEnabled && viewModel.showVoiceMeter {
                            voiceMeterRow
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.voiceScrollEnabled && viewModel.showVoiceMeter)
                    #endif

                    controlBar
                }
                .background(Color(hex: customization.backgroundColorHex))
                .opacity(viewModel.transparency)
            }
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline)
                    }
                }
                #endif
            }
            #if !os(watchOS)
            .onKeyPress(.space) { viewModel.togglePlayPause(); return .handled }
            .onKeyPress(.upArrow) {
                viewModel.scrollSpeed = min(viewModel.scrollSpeed + 0.1, AppConstants.maxScrollSpeed)
                return .handled
            }
            .onKeyPress(.downArrow) {
                viewModel.scrollSpeed = max(viewModel.scrollSpeed - 0.1, AppConstants.minScrollSpeed)
                return .handled
            }
            .onKeyPress(KeyEquivalent("r")) { viewModel.resetToTop(); return .handled }
            .sheet(isPresented: $showingPaywall) {
                PaywallView().environmentObject(storeKit)
            }
            .alert("Microphone Access Required", isPresented: $viewModel.micPermissionDenied) {
                Button("Open Settings") { openMicSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Voice Scroll needs microphone access to detect when you are speaking.")
            }
            #endif
        }
        #endif
    }

    // MARK: - iOS Body (Music Player Layout)

    #if os(iOS)
    private var iOSBody: some View {
        ZStack(alignment: .top) {
            contentBackground.ignoresSafeArea()

            if let session = cameraService.captureSession {
                CameraPreviewRepresentable(session: session).ignoresSafeArea()
                // Dimming layer for legibility over the camera feed
                Color.black.opacity(0.42).ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // Dismiss button row
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Scrolling teleprompter text
                GeometryReader { geo in
                    scrollingContent(
                        screenSize: geo.size,
                        textColor: cameraService.isCameraActive ? .white : nil
                    )
                    .clipped()
                    .onAppear {
                        viewModel.screenHeight = geo.size.height
                        viewModel.scrollSpeed = customization.scrollSpeed
                        viewModel.transparency = customization.transparency
                    }
                }
                .onTapGesture {
                    if viewModel.isTapToAdvance { viewModel.tapAdvance() }
                }
            }
        }
        .opacity(viewModel.transparency)
        .statusBarHidden(true)
        .sheet(isPresented: .constant(true)) {
            iOSPlayerPanel
                .sheet(isPresented: $showingPaywall) {
                    PaywallView().environmentObject(storeKit)
                }
                .presentationDetents([.height(96), .height(420)], selection: $playerDetent)
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(420)))
                .interactiveDismissDisabled()
        }
        .alert("Microphone Access Required", isPresented: $viewModel.micPermissionDenied) {
            Button("Open Settings") { openMicSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Voice Scroll needs microphone access to detect when you are speaking.")
        }
        .alert("Camera & Microphone Access Required", isPresented: $cameraService.permissionDenied) {
            Button("Open Settings") { openMicSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Camera mode needs camera and microphone access to record video.")
        }
        .alert("Recording Saved", isPresented: $cameraService.recordingSaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your recording has been saved to the Photos library.")
        }
        .onDisappear { cameraService.stopCamera() }
    }

    private var iOSPlayerPanel: some View {
        Group {
            if playerDetent == .height(96) {
                iOSCompactPanel
            } else {
                iOSFullPanel
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: playerDetent)
    }

    // Compact strip shown when sheet is minimised
    private var iOSCompactPanel: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(String(format: "%d%% complete", Int(viewModel.progress * 100)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { viewModel.resetToTop() } label: {
                Image(systemName: "backward.end.fill").font(.title3)
            }
            .accessibilityLabel("Reset to top")
            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
        }
        .tint(.primary)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    // Full music-player panel
    private var iOSFullPanel: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(script.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(String(format: "%d%% complete", Int(viewModel.progress * 100)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(get: { viewModel.progress }, set: { viewModel.seek(to: $0) }),
                in: 0...1
            )
            .tint(.primary)

            HStack(spacing: 44) {
                Button { viewModel.resetToTop() } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                .accessibilityLabel("Reset to top")

                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                // Record button when in camera mode, spacer otherwise
                if teleprompterMode == .camera {
                    Button { cameraService.toggleRecording() } label: {
                        Image(systemName: cameraService.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                            .foregroundStyle(cameraService.isRecording ? .red : .primary)
                    }
                    .accessibilityLabel(cameraService.isRecording ? "Stop Recording" : "Start Recording")
                } else {
                    Color.clear.frame(width: 28, height: 28)
                }
            }

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $viewModel.scrollSpeed,
                           in: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                           step: 0.1)
                        .tint(.primary)
                    Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
                }
                Text(String(format: "%.1fx speed", viewModel.scrollSpeed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Mode selector (Camera-app style)
            modeSelector

            // Voice meter — contextual, only in voice mode
            if teleprompterMode == .voice && viewModel.voiceScrollEnabled && viewModel.showVoiceMeter {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary)
                    VoiceLevelMeterView(service: viewModel.voiceScrollService)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { viewModel.showVoiceMeter = false }
                    } label: {
                        Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide level meter")
                }
                .padding(.vertical, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .tint(.primary)
        .animation(.easeInOut(duration: 0.2), value: teleprompterMode)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Mode selector

    private var modeSelector: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 0) {
                        ForEach(TeleprompterMode.allCases, id: \.self) { mode in
                            modeSelectorItem(mode)
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(TeleprompterMode.allCases, id: \.self) { mode in
                        modeSelectorItem(mode)
                    }
                }
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func modeSelectorItem(_ mode: TeleprompterMode) -> some View {
        if teleprompterMode == mode {
            if #available(iOS 26, *) {
                Button { selectMode(mode) } label: { modeSelectorLabel(mode, selected: true) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())
                    .glassEffectUnion(id: "modeSelector", namespace: modeNamespace)
            } else {
                Button { selectMode(mode) } label: { modeSelectorLabel(mode, selected: true) }
                    .buttonStyle(.plain)
                    .background(Capsule().fill(.primary.opacity(0.15)))
            }
        } else {
            Button { selectMode(mode) } label: { modeSelectorLabel(mode, selected: false) }
                .buttonStyle(.plain)
        }
    }

    private func modeSelectorLabel(_ mode: TeleprompterMode, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: mode.icon).font(.caption2)
            Text(mode.rawValue)
        }
        .font(.caption.bold())
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func selectMode(_ mode: TeleprompterMode) {
        guard mode != teleprompterMode else { return }

        // Tear down current mode
        switch teleprompterMode {
        case .tap:    viewModel.isTapToAdvance = false
        case .voice:  if viewModel.voiceScrollEnabled { Task { await viewModel.toggleVoiceScroll() } }
        case .camera: cameraService.stopCamera()
        case .auto:   break
        }

        // Activate new mode
        switch mode {
        case .auto:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { teleprompterMode = .auto }
        case .tap:
            viewModel.isTapToAdvance = true
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { teleprompterMode = .tap }
        case .voice:
            guard storeKit.isPremium else { showingPaywall = true; return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { teleprompterMode = .voice }
            Task { await viewModel.toggleVoiceScroll() }
        case .camera:
            guard storeKit.isPremium else { showingPaywall = true; return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { teleprompterMode = .camera }
            Task { await cameraService.requestPermissionsAndStart() }
        }
    }
    #endif

    // MARK: - Scrolling content

    private func scrollingContent(screenSize: CGSize, textColor: Color? = nil) -> some View {
        let text = script.content.isEmpty ? "[ Empty script ]" : script.content
        return Text(text)
            .font(.custom(customization.fontName, size: customization.fontSize))
            .foregroundStyle(textColor ?? Color(hex: customization.textColorHex))
            .multilineTextAlignment(customization.textAlignmentIndex.textAlignment)
            .lineSpacing((customization.lineHeight - 1.0) * customization.fontSize * 0.5)
            .padding()
            .frame(maxWidth: .infinity, alignment: customization.textAlignmentIndex.frameAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(x: customization.isMirrored ? -1 : 1, y: 1)
            .background(
                GeometryReader { contentGeo in
                    Color.clear
                        .preference(key: ContentHeightKey.self, value: contentGeo.size.height)
                        .onAppear { viewModel.contentHeight = contentGeo.size.height }
                }
            )
            .offset(y: -viewModel.contentOffset)
            .onPreferenceChange(ContentHeightKey.self) { viewModel.contentHeight = $0 }
    }

    // MARK: - Voice meter row (macOS)

    #if !os(watchOS) && !os(iOS)
    private var voiceMeterRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))

            VoiceLevelMeterView(service: viewModel.voiceScrollService)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { viewModel.showVoiceMeter = false }
            } label: {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide level meter")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
        }
    }
    #endif

    // MARK: - Control bar (macOS + watchOS)

    #if !os(iOS)
    private var controlBar: some View {
        HStack(spacing: 18) {
            Button { viewModel.resetToTop() } label: {
                Image(systemName: "backward.end.fill").font(.title3)
            }
            .accessibilityLabel("Reset to top")

            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 46))
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Slider(
                value: $viewModel.scrollSpeed,
                in: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                step: 0.1
            )

            Text(String(format: "%.1fx", viewModel.scrollSpeed))
                .font(.caption.bold().monospacedDigit())
                .frame(width: 40, alignment: .trailing)

            Toggle(isOn: $viewModel.isTapToAdvance) {
                Image(systemName: "hand.tap.fill").font(.footnote)
            }
            .toggleStyle(.button)
            .tint(.white.opacity(0.3))
            .accessibilityLabel("Tap to advance")

            #if !os(watchOS)
            Button {
                if storeKit.isPremium {
                    Task { await viewModel.toggleVoiceScroll() }
                } else {
                    showingPaywall = true
                }
            } label: {
                Image(systemName: viewModel.voiceScrollEnabled ? "mic.fill" : "mic")
                    .font(.footnote)
                    .foregroundStyle(viewModel.voiceScrollEnabled ? Color.green : Color.white)
            }
            .accessibilityLabel(viewModel.voiceScrollEnabled ? "Disable Voice Scroll" : "Enable Voice Scroll")

            if viewModel.voiceScrollEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { viewModel.showVoiceMeter.toggle() }
                } label: {
                    Image(systemName: viewModel.showVoiceMeter ? "waveform" : "waveform.slash")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(viewModel.showVoiceMeter ? 1.0 : 0.5))
                }
                .accessibilityLabel(viewModel.showVoiceMeter ? "Hide level meter" : "Show level meter")
            }
            #endif
        }
        .tint(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
        }
    }
    #endif

    // MARK: - Helpers

    #if !os(watchOS)
    private func openMicSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
    #endif
}

#if os(iOS)
private struct CameraPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#endif
