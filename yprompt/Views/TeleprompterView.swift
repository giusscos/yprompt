//
//  TeleprompterView.swift
//  yprompt
//

import SwiftUI

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct TeleprompterView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var script: Script
    @StateObject private var viewModel = TeleprompterViewModel()
    #if os(iOS)
    @ObservedObject private var pipManager = TeleprompterPiPManager.shared
    #endif
    #if !os(watchOS)
    @EnvironmentObject private var storeKit: StoreKitService
    @State private var showingPaywall = false
    #endif

    private var customization: TextCustomization { script.customization }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    scrollingContent(screenSize: geo.size)
                        .clipped()
                        .onAppear {
                            viewModel.screenHeight = geo.size.height
                            viewModel.scrollSpeed = customization.scrollSpeed
                            viewModel.transparency = customization.transparency
                            #if os(iOS)
                            pipManager.configure(script: script, viewModel: viewModel)
                            #endif
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
            #if os(iOS)
            .statusBarHidden(true)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline)
                    }
                }
                #endif
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
    }

    // MARK: - Scrolling content

    private func scrollingContent(screenSize: CGSize) -> some View {
        let text = script.content.isEmpty ? "[ Empty script ]" : script.content
        return Text(text)
            .font(.custom(customization.fontName, size: customization.fontSize))
            .foregroundStyle(Color(hex: customization.textColorHex))
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

    // MARK: - Voice meter row

    #if !os(watchOS)
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

    // MARK: - Control bar

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

            #if os(iOS)
            if pipManager.isPiPAvailable {
                Button { pipManager.togglePiP() } label: {
                    Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                        .font(.footnote)
                }
                .accessibilityLabel(pipManager.isPiPActive ? "Exit Picture in Picture" : "Picture in Picture")
            }
            #endif

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
