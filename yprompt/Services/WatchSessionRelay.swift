//
//  WatchSessionRelay.swift
//  yprompt
//

#if os(iOS)
import WatchConnectivity
import Foundation
import Combine

// Receives RemoteControlCommand messages from the paired Apple Watch.
// If the iPhone is connected to a Mac via MultipeerConnectivity, the command
// is relayed to the Mac. Otherwise, onCommandReceived is called for local handling.
@MainActor
final class WatchSessionRelay: NSObject {
    static let shared = WatchSessionRelay()

    var onCommandReceived: ((RemoteControlCommand) -> Void)?
    /// Local iPhone scripts — set by ContentView so Watch can list them when not bridged to a Mac.
    var localScripts: [Script] = []

    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        // Auto-push to Watch whenever the Mac sends an updated script list to the iPhone.
        RemoteControlService.shared.$availableScripts
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sendScriptListToWatch() }
            .store(in: &cancellables)
    }

    func activate() {
        // Accessing shared triggers init which activates the WCSession.
    }

    // Pushes the current script list (and mode state) to the Watch on demand.
    func sendScriptListToWatch() {
        guard WCSession.default.isReachable else { return }

        let remote = RemoteControlService.shared
        let scripts: [[String: String]]
        let currentID: String?
        let notchMode: Bool
        let voiceScrollEnabled: Bool
        let timedDuration: TimeInterval?

        if remote.isConnected && !remote.availableScripts.isEmpty {
            // iPhone is bridged to Mac — use Mac's state
            scripts = remote.availableScripts.map { ["id": $0.id.uuidString, "title": $0.title] }
            currentID = remote.currentRemoteScriptID?.uuidString
            notchMode = remote.remoteNotchMode
            voiceScrollEnabled = remote.remoteVoiceScrollEnabled
            timedDuration = remote.remoteTimedDuration
        } else {
            // Standalone iPhone — use local SwiftData scripts
            scripts = localScripts.map { ["id": $0.id.uuidString, "title": $0.title] }
            currentID = nil
            notchMode = false
            voiceScrollEnabled = false
            timedDuration = nil
        }

        var message: [String: Any] = [
            "scripts": scripts,
            "notchMode": notchMode,
            "voiceScrollEnabled": voiceScrollEnabled
        ]
        if let currentID { message["currentID"] = currentID }
        if let timedDuration { message["timedDuration"] = timedDuration }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    // Sends a haptic pulse to the Watch when a cue point is crossed.
    func sendHapticCue() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": "hapticCue"], replyHandler: nil, errorHandler: nil)
    }
}

extension WatchSessionRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after paired Watch switch.
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let cmdString = message["command"] as? String else { return }

        if cmdString == "requestScripts" {
            Task { @MainActor in self.sendScriptListToWatch() }
            return
        }

        Task { @MainActor in
            let command: RemoteControlCommand
            if cmdString == "setSpeed", let speed = message["speed"] as? Double {
                command = .setSpeed(speed)
            } else if cmdString == "selectScript",
                      let idStr = message["id"] as? String,
                      let uuid = UUID(uuidString: idStr) {
                command = .selectScript(uuid)
            } else if cmdString == "setNotchMode", let value = message["value"] as? Bool {
                command = .setNotchMode(value)
            } else if cmdString == "setVoiceScroll", let value = message["value"] as? Bool {
                command = .setVoiceScroll(value)
            } else if cmdString == "setTimedDuration" {
                let duration = message["duration"] as? Double
                command = .setTimedDuration(duration)
            } else if let cmd = RemoteControlCommand(rawValue: cmdString) {
                command = cmd
            } else {
                return
            }

            if RemoteControlService.shared.isConnected {
                RemoteControlService.shared.send(command: command)
            } else {
                self.onCommandReceived?(command)
            }
        }
    }
}
#endif
