//
//  VoiceLevelMeterView.swift
//  yprompt
//

#if !os(watchOS)
import SwiftUI

struct VoiceLevelMeterView: View {
    @ObservedObject var service: VoiceScrollService

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary)

                // Level fill — green when speaking, dim when silent
                RoundedRectangle(cornerRadius: 5)
                    .fill(service.isSpeaking ? Color.green.opacity(0.70) : Color.orange.opacity(0.70))
                    .frame(width: max(6, geo.size.width * CGFloat(service.normalizedLevel)))
                    .animation(.easeOut(duration: 0.06), value: service.normalizedLevel)

                // Threshold marker — yellow vertical line the user can drag
                let markerX = geo.size.width * CGFloat(service.normalizedThreshold)
                ZStack {
                    Capsule()
                        .fill(Color.yellow)
                        .frame(width: 3, height: geo.size.height + 6)
                    // Wider invisible hit area for easier dragging
                    Color.clear
                        .frame(width: 28, height: geo.size.height + 8)
                        .contentShape(Rectangle())
                }
                .offset(x: max(0, min(geo.size.width - 3, markerX - 1)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let normalized = Float(value.location.x / geo.size.width)
                        service.speechThreshold = VoiceScrollService.denormalize(max(0, min(1, normalized)))
                    }
            )
            .frame(height: 10)
        }
        .frame(height: 10)
    }
}
#endif
