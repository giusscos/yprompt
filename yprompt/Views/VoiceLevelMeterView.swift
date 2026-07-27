//
//  VoiceLevelMeterView.swift
//  yprompt
//

#if !os(watchOS)
import SwiftUI

struct VoiceLevelMeterView: View {
    var service: VoiceScrollService
    /// When true, renders a status row above the meter (used in the iOS player sheet).
    var showStatus: Bool = false

    var body: some View {
        if showStatus {
            VStack(spacing: 8) {
                statusRow
                meterBar
            }
        } else {
            meterBar
        }
    }

    private var statusRow: some View {
        HStack(spacing: 7) {
            ZStack {
                if service.isSpeaking {
                    Circle()
                        .fill(Color.green.opacity(0.28))
                        .frame(width: 14, height: 14)
                        .transition(.scale.combined(with: .opacity))
                }
                Circle()
                    .fill(service.isSpeaking ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
            }
            .animation(.easeInOut(duration: 0.12), value: service.isSpeaking)

            Text(service.isSpeaking ? "Speaking — scrolling" : "Listening for your voice...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .animation(nil, value: service.isSpeaking)

            Spacer()

            Text("Drag  ▲  to adjust")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var meterBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))

                // Level fill — gradient when speaking, muted when silent
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        service.isSpeaking
                        ? AnyShapeStyle(LinearGradient(
                            colors: [.green.opacity(0.65), .teal.opacity(0.8)],
                            startPoint: .leading, endPoint: .trailing
                          ))
                        : AnyShapeStyle(Color.secondary.opacity(0.28))
                    )
                    .frame(width: max(6, geo.size.width * CGFloat(service.normalizedLevel)))
                    .animation(.easeOut(duration: 0.06), value: service.normalizedLevel)

                // Threshold marker — draggable yellow tick
                let markerX = geo.size.width * CGFloat(service.normalizedThreshold)
                ZStack {
                    Capsule()
                        .fill(Color.yellow)
                        .frame(width: 2, height: geo.size.height + 10)
                    Color.clear
                        .frame(width: 32, height: geo.size.height + 10)
                        .contentShape(Rectangle())
                }
                .offset(x: max(0, min(geo.size.width - 2, markerX - 1)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let normalized = Float(value.location.x / geo.size.width)
                        service.speechThreshold = VoiceScrollService.denormalize(max(0, min(1, normalized)))
                    }
            )
        }
        .frame(height: 14)
    }
}
#endif
