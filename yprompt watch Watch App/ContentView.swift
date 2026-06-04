//
//  ContentView.swift
//  yprompt watch Watch App
//

import SwiftUI

// MARK: - Root

struct ContentView: View {
    @StateObject private var remote = WatchRemoteService.shared
    @State private var localSpeed: Double = 1.0
    @State private var isPlaying = false

    var body: some View {
        NavigationStack {
            ControlsPage(remote: remote)
                .navigationTitle("yPrompt")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isPlaying.toggle()
                            remote.send(command: "togglePlayPause")
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .disabled(!remote.isPhoneReachable)
                        .opacity(remote.isPhoneReachable ? 1 : 0.4)
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(remote.isPhoneReachable ? Color.green : Color.gray)
                                .frame(width: 5, height: 5)
                            Text(remote.isPhoneReachable ? "ON" : "OFF")
                                .font(.caption2.bold().width(.compressed))
                                .foregroundStyle(.secondary)
                        }
                    }

                    ToolbarItem(placement: .bottomBar) {
                        HStack(spacing: 6) {
                            Button {
                                let s = max(0.5, round((localSpeed - 0.1) * 10) / 10)
                                localSpeed = s
                                remote.sendSpeed(s)
                            } label: {
                                Image(systemName: "minus")
                            }
                            .disabled(localSpeed <= 0.5 || !remote.isPhoneReachable)

                            Text(String(format: "%.1f", localSpeed))
                                .font(.footnote.weight(.semibold).monospaced())
                                .animation(.spring())
                                .contentTransition(.numericText(value: localSpeed))

                            Button {
                                let s = min(3.0, round((localSpeed + 0.1) * 10) / 10)
                                localSpeed = s
                                remote.sendSpeed(s)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .disabled(localSpeed >= 3.0 || !remote.isPhoneReachable)

                            Spacer()

                            Button(role: .destructive) {
                                isPlaying = false
                                remote.send(command: "reset")
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .tint(.red)
                            .disabled(!remote.isPhoneReachable)
                        }
                    }
                }
        }
        .background(LinearGradient(colors: [.purple.opacity(0.7), .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottom))
    }
}

// MARK: - Controls

private struct ControlsPage: View {
    @ObservedObject var remote: WatchRemoteService

    var body: some View {
        VStack(spacing: 16) {
            HoldScrollButton(icon: "arrowtriangle.up.fill", isEnabled: remote.isPhoneReachable) {
                remote.startContinuous("startContinuousUp")
            } onRelease: {
                remote.stopContinuous()
            }

            HoldScrollButton(icon: "arrowtriangle.down.fill", isEnabled: remote.isPhoneReachable) {
                remote.startContinuous("startContinuousDown")
            } onRelease: {
                remote.stopContinuous()
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Hold Scroll Button

private struct HoldScrollButton: View {
    let icon: String
    let isEnabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Image(systemName: icon)
            .resizable()
            .frame(width: 72, height: 42)
            .foregroundStyle(.secondary)
            .scaleEffect(isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: isPressed)
            .opacity(isEnabled ? 1 : 0.35)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        isPressed = false
                        onRelease()
                    }
            )
    }
}

#Preview {
    ContentView()
}
