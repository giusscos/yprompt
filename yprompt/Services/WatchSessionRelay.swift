//
//  WatchSessionRelay.swift
//  yprompt
//

#if os(iOS)
import WatchConnectivity
import Foundation

// Receives RemoteControlCommand messages from the paired Apple Watch.
// If the iPhone is connected to a Mac via MultipeerConnectivity, the command
// is relayed to the Mac. Otherwise, onCommandReceived is called for local handling.
@MainActor
final class WatchSessionRelay: NSObject {
    static let shared = WatchSessionRelay()

    var onCommandReceived: ((RemoteControlCommand) -> Void)?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func activate() {
        // Accessing shared triggers init which activates the WCSession.
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
        guard let cmdString = message["command"] as? String,
              let command = RemoteControlCommand(rawValue: cmdString) else { return }
        Task { @MainActor in
            if RemoteControlService.shared.isConnected {
                // Relay the command to the connected Mac.
                RemoteControlService.shared.send(command: command)
            } else {
                // Handle locally (e.g. iPhone running its own teleprompter).
                self.onCommandReceived?(command)
            }
        }
    }
}
#endif
