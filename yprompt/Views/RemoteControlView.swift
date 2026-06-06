//
//  RemoteControlView.swift
//  yprompt
//

#if !os(macOS) && !os(watchOS)
import SwiftUI
import UIKit
import MultipeerConnectivity

struct RemoteControlView: View {
    @StateObject private var remote = RemoteControlService.shared
    @Environment(StoreKitService.self) private var storeKit
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showPaywall = false
    @State private var localSpeed: Double = AppConstants.defaultScrollSpeed
    @State private var isPlayingLocal: Bool = false

    var body: some View {
        Group {
            if !storeKit.isPremium {
                premiumPrompt
            } else if remote.isConnected {
                controlPanel
            } else {
                deviceBrowser
            }
        }
        .navigationTitle("Remote")
        .navigationSubtitle(remote.isConnected ? (remote.connectedPeers.first?.displayName ?? "Connected") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if remote.isConnected {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Disconnect") { remote.disconnect() }
                        .foregroundStyle(.red)
                }
                if !remote.availableScripts.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Picker("Script", selection: Binding(
                            get: { remote.currentRemoteScriptID },
                            set: { id in
                                guard let id else { return }
                                remote.send(command: .selectScript(id))
                                remote.currentRemoteScriptID = id
                                isPlayingLocal = false
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                        )) {
                            Text("Select script…").tag(Optional<UUID>.none)
                            ForEach(remote.availableScripts) { script in
                                Text(script.title).tag(Optional(script.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
        }
        .onAppear {
            if storeKit.isPremium { remote.startBrowsing() }
        }
        .onDisappear {
            remote.stopBrowsing()
        }
        .onChange(of: remote.isConnected) { _, connected in
            if !connected {
                localSpeed = AppConstants.defaultScrollSpeed
                isPlayingLocal = false
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environment(storeKit)
        }
    }

    // MARK: - Premium Gate

    private var premiumPrompt: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Text("iPhone Remote Control")
                    .font(.title2.bold())
                Text("Control your Mac teleprompter from your iPhone over Wi-Fi or Bluetooth.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Unlock Premium") {
                showPaywall = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Device Browser

    private var deviceBrowser: some View {
        VStack(spacing: 0) {
            if remote.discoveredPeers.isEmpty {
                VStack(spacing: 20) {
                    Spacer()
                    ProgressView().scaleEffect(1.4)
                    VStack(spacing: 8) {
                        Text("Searching for your Mac…")
                            .font(.headline)
                        Text("Make sure YPrompt is open on your Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .padding(.horizontal, 32)
            } else {
                List {
                    Section("Available Macs") {
                        ForEach(remote.discoveredPeers, id: \.self) { peer in
                            Button {
                                remote.connect(to: peer)
                            } label: {
                                Label(peer.displayName, systemImage: "desktopcomputer")
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    // MARK: - Control Panel

    private var dpad: some View {
        DPadControl(
            onPressUp:    { remote.send(command: .startContinuousUp) },
            onPressDown:  { remote.send(command: .startContinuousDown) },
            onPressLeft:  { remote.send(command: .startContinuousUp) },
            onPressRight: { remote.send(command: .startContinuousDown) },
            onRelease:    { remote.send(command: .stopContinuous) },
            onReset:      { remote.send(command: .reset) }
        )
    }

    private var controlPanel: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 0) {
                    Spacer()
                    dpad
                    Spacer()
                    VStack(spacing: 28) {
                        playPauseSection
                        speedSection
                    }
                    .padding(.horizontal, 20)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 28) {
                        dpad
                        playPauseSection
                        speedSection
                    }
                    .padding(.horizontal, 20)
                    Spacer()
                }
            }
        }
    }


    // MARK: - Play / Pause

    private var playPauseSection: some View {
        Button {
            isPlayingLocal.toggle()
            remote.send(command: .togglePlayPause)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            Image(systemName: isPlayingLocal ? "pause.fill" : "play.fill")
                .font(.system(size: 32, weight: .semibold))
                .padding(20)
                .symbolEffect(.bounce, value: isPlayingLocal)
        }
        .buttonStyle(.glass)
    }

    // MARK: - Speed

    private var speedSection: some View {
        VStack(spacing: 12) {
            Text("Speed")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Button {
                    let newSpeed = max(AppConstants.minScrollSpeed, (round((localSpeed - 0.1) * 10) / 10))
                    localSpeed = newSpeed
                    remote.send(command: .setSpeed(newSpeed))
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 20, weight: .semibold))
                        .padding(14)
                }
                .buttonStyle(.glass)
                .disabled(localSpeed <= AppConstants.minScrollSpeed)

                Text(String(format: "%.1f", localSpeed))
                    .font(.title.bold().monospacedDigit())
                    .frame(minWidth: 60)
                    .contentTransition(.numericText())
                    .animation(.default, value: localSpeed)

                Button {
                    let newSpeed = min(AppConstants.maxScrollSpeed, (round((localSpeed + 0.1) * 10) / 10))
                    localSpeed = newSpeed
                    remote.send(command: .setSpeed(newSpeed))
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .padding(14)
                }
                .buttonStyle(.glass)
                .disabled(localSpeed >= AppConstants.maxScrollSpeed)
            }
        }
    }

}

// MARK: - D-Pad

private enum DPadDirection { case up, down, left, right }

private struct DPadControl: View {
    let onPressUp: () -> Void
    let onPressDown: () -> Void
    let onPressLeft: () -> Void
    let onPressRight: () -> Void
    let onRelease: () -> Void
    let onReset: () -> Void

    @State private var activeDirection: DPadDirection? = nil

    private let dpadSize: CGFloat = 280
    private let centerSize: CGFloat = 88
    private let hitSize: CGFloat = 84
    private let hitOffset: CGFloat = 82

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemFill))
                .frame(width: dpadSize, height: dpadSize)

            DPadArrow(direction: .up,    icon: "chevron.up",
                      offset: CGSize(width: 0, height: -hitOffset),
                      hitSize: hitSize, activeDirection: $activeDirection,
                      onPress: onPressUp, onRelease: onRelease)

            DPadArrow(direction: .down,  icon: "chevron.down",
                      offset: CGSize(width: 0, height: hitOffset),
                      hitSize: hitSize, activeDirection: $activeDirection,
                      onPress: onPressDown, onRelease: onRelease)

            DPadArrow(direction: .left,  icon: "chevron.left",
                      offset: CGSize(width: -hitOffset, height: 0),
                      hitSize: hitSize, activeDirection: $activeDirection,
                      onPress: onPressLeft, onRelease: onRelease)

            DPadArrow(direction: .right, icon: "chevron.right",
                      offset: CGSize(width: hitOffset, height: 0),
                      hitSize: hitSize, activeDirection: $activeDirection,
                      onPress: onPressRight, onRelease: onRelease)

            DPadCenter(size: centerSize, onTap: onReset)
        }
        .frame(width: dpadSize, height: dpadSize)
    }
}

// MARK: - D-Pad Arrow

private struct DPadArrow: View {
    let direction: DPadDirection
    let icon: String
    let offset: CGSize
    let hitSize: CGFloat
    @Binding var activeDirection: DPadDirection?
    let onPress: () -> Void
    let onRelease: () -> Void

    private var isPressed: Bool { activeDirection == direction }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: hitSize, height: hitSize)
            .contentShape(Circle())
            .offset(offset)
            .scaleEffect(isPressed ? 0.78 : 1.0)
            .animation(.easeInOut(duration: 0.07), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard activeDirection == nil else { return }
                        activeDirection = direction
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onPress()
                    }
                    .onEnded { _ in
                        guard activeDirection == direction else { return }
                        activeDirection = nil
                        onRelease()
                    }
            )
    }
}

// MARK: - D-Pad Center (Reset)

private struct DPadCenter: View {
    let size: CGFloat
    let onTap: () -> Void

    @State private var pressed = false

    var body: some View {
        Circle()
            .fill(Color(.secondarySystemFill))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
            )
            .scaleEffect(pressed ? 0.88 : 1.0)
            .animation(.easeInOut(duration: 0.07), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                    }
                    .onEnded { _ in
                        pressed = false
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onTap()
                    }
            )
    }
}

#Preview {
    NavigationStack {
        RemoteControlView()
    }
    .environment(StoreKitService())
}
#endif
