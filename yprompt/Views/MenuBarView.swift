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
                launchButton
                if manager.isVisible {
                    playbackControls
                    appearanceControls
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
            HStack(spacing: 10) {
                Button { viewModel.togglePlayPause() } label: {
                    Label(
                        viewModel.isPlaying ? "Pause" : "Play",
                        systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)

                Spacer()

                Button { viewModel.resetToTop() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .help("Reset to top")
            }

            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: $viewModel.scrollSpeed,
                    in: AppConstants.minScrollSpeed...AppConstants.maxScrollSpeed,
                    step: 0.1
                )
                Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1fx", viewModel.scrollSpeed))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 30, alignment: .trailing)
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
                Slider(value: $manager.backgroundOpacity, in: 0.15...1.0, step: 0.05)
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
                Slider(value: $manager.blurAmount, in: 0.0...1.0, step: 0.05)
                Text("\(Int(manager.blurAmount * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }
}
#endif
