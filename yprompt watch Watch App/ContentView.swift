//
//  ContentView.swift
//  yprompt watch Watch App
//

import SwiftUI
import WatchConnectivity

struct ContentView: View {
    @StateObject private var remote = WatchRemoteService.shared

    @State private var crownValue: Double = 0
    @State private var lastCrownValue: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                // Connection status
                HStack(spacing: 6) {
                    Circle()
                        .fill(remote.isPhoneReachable ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(remote.isPhoneReachable ? "iPhone Connected" : "iPhone Unreachable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Scroll Up
                Button {
                    remote.nudge("startContinuousUp")
                } label: {
                    Label("Scroll Up", systemImage: "chevron.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!remote.isPhoneReachable)

                // Play / Pause
                Button {
                    remote.send(command: "togglePlayPause")
                } label: {
                    Image(systemName: "playpause.fill")
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!remote.isPhoneReachable)

                // Scroll Down
                Button {
                    remote.nudge("startContinuousDown")
                } label: {
                    Label("Scroll Down", systemImage: "chevron.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!remote.isPhoneReachable)

                // Reset
                Button {
                    remote.send(command: "reset")
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!remote.isPhoneReachable)

                Text("Rotate crown to scroll")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            .navigationTitle("YPrompt")
        }
        .onAppear { lastCrownValue = crownValue }
        .focusable()
        .digitalCrownRotation(
            $crownValue,
            from: -100000,
            through: 100000,
            by: 1.0,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownValue) { _, new in
            let delta = new - lastCrownValue
            lastCrownValue = new
            guard abs(delta) > 0.1 else { return }
            remote.crownScrolled(forward: delta > 0)
        }
    }
}

#Preview {
    ContentView()
}
