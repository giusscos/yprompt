//
//  MenuBarView.swift
//  yprompt
//

#if os(macOS)
import SwiftUI
import SwiftData

struct MenuBarView: View {
    @ObservedObject private var manager: FloatingTeleprompterManager
    @ObservedObject private var viewModel: TeleprompterViewModel
    @Query(sort: \Script.modifiedAt, order: .reverse) private var scripts: [Script]
    @State private var selectedScriptID: Script.ID?
    @State private var menuTimedEnabled = false
    @State private var menuTimedMinutes: Int = 3
    @State private var showTimedUpgradeAlert = false

    init() {
        let mgr = FloatingTeleprompterManager.shared
        _manager = ObservedObject(wrappedValue: mgr)
        _viewModel = ObservedObject(wrappedValue: mgr.viewModel)
    }

    private var selectedScript: Script? {
        guard let id = selectedScriptID else { return nil }
        return scripts.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                scriptPicker
                modeSelector
                launchButton
                if manager.isVisible {
                    playbackControls
                    fontSizeControl
                    if !manager.notchMode {
                        appearanceControls
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 290)
        .onAppear {
            if selectedScriptID == nil {
                selectedScriptID = manager.currentScript?.id ?? scripts.first?.id
            }
        }
        .alert("Premium Feature", isPresented: $showTimedUpgradeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Timer mode is available with YPrompt Premium. Open the main app to upgrade.")
        }
    }

    // MARK: - Helpers

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func updateMenuTimedDuration() {
        let total = TimeInterval(menuTimedMinutes * 60)
        viewModel.timedDuration = total > 0 ? total : 180
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Image(systemName: "scroll")
                .foregroundStyle(.tint)
            Text("YPrompt").font(.headline)
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .filter { !($0 is NSPanel) }
                    .first?
                    .makeKeyAndOrderFront(nil)
            } label: {
                Image(systemName: "macwindow")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open main window")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit YPrompt")
        }
        .padding(12)
    }

    // MARK: - Script picker

    @ViewBuilder
    private var scriptPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Script")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if scripts.isEmpty {
                Text("Open the app to create a script")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Picker("", selection: $selectedScriptID) {
                    ForEach(scripts) { script in
                        Text(script.title.isEmpty ? "Untitled" : script.title)
                            .tag(Optional(script.id))
                    }
                }
                .labelsHidden()
                .onChange(of: selectedScriptID) { _, newID in
                    // Live-switch script if teleprompter is already showing
                    if manager.isVisible, let script = scripts.first(where: { $0.id == newID }) {
                        manager.show(script: script)
                    }
                }
            }
        }
    }

    // MARK: - Mode selector

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Mode")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Picker("Mode", selection: $manager.notchMode) {
                Label("Floating", systemImage: "rectangle.on.rectangle").tag(false)
                Label("Notch", systemImage: "camera").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: manager.notchMode) { _, _ in
                if manager.suppressModeRestart {
                    manager.suppressModeRestart = false
                    return
                }
                if manager.isVisible, let script = manager.currentScript {
                    manager.hide()
                    manager.show(script: script)
                }
            }
        }
    }

    // MARK: - Launch / close button

    private var launchButton: some View {
        Button {
            if manager.isVisible {
                manager.hide()
            } else if let script = selectedScript {
                manager.show(script: script)
            }
        } label: {
            Label(
                manager.isVisible ? "Close Teleprompter" : "Show Teleprompter",
                systemImage: manager.isVisible ? "xmark.rectangle" : "play.rectangle.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!manager.isVisible && selectedScript == nil)
    }

    // MARK: - Playback controls (visible when floating window is open)

    private var playbackControls: some View {
        VStack(spacing: 10) {
            Divider()
            HStack {
                Button { viewModel.resetToTop() } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                .accessibilityLabel("Reset to top")
                .help("Reset to top")

                Spacer()

                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                Spacer()

                Image(systemName: "backward.end.fill").font(.title2).hidden()
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 5) {
                Text("Playback mode")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                
                Picker("Playback mode", selection: Binding(
                    get: { menuTimedEnabled ? 1 : 0 },
                    set: { newVal in
                        if newVal == 1 {
                            guard manager.isPremium else { showTimedUpgradeAlert = true; return }
                            menuTimedEnabled = true
                            updateMenuTimedDuration()
                        } else {
                            menuTimedEnabled = false
                            viewModel.timedDuration = nil
                        }
                    }
                )) {
                    Text("Standard").tag(0)
                    Text("Timer").tag(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if menuTimedEnabled {
                if viewModel.isPlaying && viewModel.timedDuration != nil {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Remaining").font(.caption).foregroundStyle(.secondary)
                        
                        Text(timeString(viewModel.remainingTime))
                            .font(.body.monospacedDigit().bold())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Select time").font(.caption).foregroundStyle(.secondary)
                        
                        HStack(spacing: 0) {
                            Button { if menuTimedMinutes > 0 { menuTimedMinutes -= 1; updateMenuTimedDuration() } } label: {
                                Image(systemName: "minus")
                                    .frame(width: 16, height: 16)
                            }
                            
                            Text("\(menuTimedMinutes)m")
                                .font(.body.monospacedDigit().bold())
                                .frame(minWidth: 44)
                            
                            Button { menuTimedMinutes = min(59, menuTimedMinutes + 1); updateMenuTimedDuration() } label: {
                                Image(systemName: "plus")
                                    .frame(width: 16, height: 16)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.secondary)
                    MusicSlider(
                        value: $viewModel.scrollSpeed,
                        range: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                        step: 0.1
                    )
                    Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.1fx", viewModel.scrollSpeed))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Font size control (visible when teleprompter is open)

    private var currentFontSize: CGFloat {
        manager.notchMode ? manager.notchFontSize : manager.floatingFontSize
    }

    private var fontSizeControl: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "textformat.size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("Font Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if manager.notchMode {
                        manager.notchFontSize = max(8, manager.notchFontSize - 1)
                    } else {
                        manager.floatingFontSize = max(12, manager.floatingFontSize - 1)
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 16, height: 16)
                }

                Text("\(Int(currentFontSize))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 26, alignment: .center)

                Button {
                    if manager.notchMode {
                        manager.notchFontSize = min(16, manager.notchFontSize + 1)
                    } else {
                        manager.floatingFontSize = min(40, manager.floatingFontSize + 1)
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
            }
        }
    }

    // MARK: - Appearance controls (visible when floating window is open)

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Text("Appearance")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            // Opacity
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                MusicSlider(value: $manager.backgroundOpacity, range: 0.15...1.0, step: 0.05)
                Text("\(Int(manager.backgroundOpacity * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }

            // Background blur
            HStack(spacing: 8) {
                Image(systemName: "camera.filters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                MusicSlider(value: $manager.blurAmount, range: 0.0...1.0, step: 0.05)
                Text("\(Int(manager.blurAmount * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }

            // Horizontal padding
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right.text.vertical")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                MusicSlider(
                    value: Binding(get: { Double(manager.horizontalPadding) }, set: { manager.horizontalPadding = CGFloat($0) }),
                    range: 0...120,
                    step: 4
                )
                Text("\(Int(manager.horizontalPadding))pt")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }
}
#endif
