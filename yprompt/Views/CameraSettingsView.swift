//
//  CameraSettingsView.swift
//  yprompt
//

#if os(iOS)
import AVFoundation
import SwiftUI

/// Lens, format and exposure controls for camera mode, shown in a popover from the player panel.
struct CameraSettingsView: View {
    @ObservedObject var camera: CameraRecordingService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if camera.canSwitchCamera {
                Picker("Camera", selection: Binding(
                    get: { camera.cameraPosition == .front },
                    set: { isFront in if isFront != (camera.cameraPosition == .front) { camera.switchCamera() } }
                )) {
                    Text("Front").tag(true)
                    Text("Back").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(camera.isRecording)
            }

            lensSection

            section("Format") {
                HStack(spacing: 10) {
                    Picker("Resolution", selection: Binding(get: { camera.resolution }, set: camera.setResolution)) {
                        ForEach(camera.supportedResolutions) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Frame Rate", selection: Binding(get: { camera.frameRate }, set: camera.setFrameRate)) {
                        ForEach(camera.supportedFrameRates, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(camera.isRecording)
                Picker("Stabilization", selection: Binding(get: { camera.stabilization }, set: camera.setStabilization)) {
                    ForEach(camera.supportedStabilizations) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(camera.isRecording)
            }

            section("Exposure") {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposureBias(Float($0)) }),
                        in: Double(camera.exposureBiasRange.lowerBound)...Double(max(camera.exposureBiasRange.upperBound, camera.exposureBiasRange.lowerBound + 0.1)),
                        step: 0.1
                    )
                    Image(systemName: "sun.max.fill").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(camera.isFocusExposureLocked)
                Text(String(format: String(localized: "%+.1f EV"), camera.exposureBias))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Toggle(isOn: Binding(get: { camera.isFocusExposureLocked }, set: camera.setFocusExposureLocked)) {
                    Label("Lock Focus & Exposure", systemImage: "lock.fill")
                }
                if camera.hasTorch {
                    Toggle(isOn: Binding(get: { camera.isTorchOn }, set: camera.setTorch)) {
                        Label("Light", systemImage: camera.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    }
                }
            }
        }
        .frame(minWidth: 300)
    }

    @ViewBuilder
    private var lensSection: some View {
        section("Lens") {
            if camera.lenses.count > 1 {
                HStack(spacing: 8) {
                    ForEach(camera.lenses) { lens in
                        let isActive = activeLens?.id == lens.id
                        Button { camera.selectLens(lens) } label: {
                            Text(isActive ? CameraRecordingService.zoomLabel(camera.displayZoom) : lens.label)
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .frame(minWidth: 44, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(isActive ? .yellow : .secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { Double(camera.zoomFactor) }, set: { camera.setZoom(CGFloat($0)) }),
                    in: Double(camera.zoomRange.lowerBound)...Double(max(camera.zoomRange.upperBound, camera.zoomRange.lowerBound + 0.01))
                )
                Image(systemName: "plus.magnifyingglass").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(camera.zoomRange.upperBound <= camera.zoomRange.lowerBound)
        }
    }

    /// The lens currently in use: the last one whose switch-over zoom has been reached.
    private var activeLens: CameraLens? {
        camera.lenses.last { camera.zoomFactor >= $0.zoomFactor - 0.01 } ?? camera.lenses.first
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}
#endif
