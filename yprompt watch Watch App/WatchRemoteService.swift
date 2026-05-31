//
//  WatchRemoteService.swift
//  yprompt watch Watch App
//

import WatchConnectivity
import Foundation
import Combine

@MainActor
final class WatchRemoteService: NSObject, ObservableObject {
    static let shared = WatchRemoteService()

    @Published var isPhoneReachable = false

    private var stopTask: Task<Void, Never>?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(command: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": command], replyHandler: nil, errorHandler: nil)
    }

    // Sends a "nudge": starts continuous scroll then auto-stops after 400ms.
    func nudge(_ command: String) {
        send(command: command)
        stopTask?.cancel()
        stopTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            send(command: "stopContinuous")
        }
    }

    // Called by Digital Crown changes; debounces the stop signal.
    func crownScrolled(forward: Bool) {
        let cmd = forward ? "startContinuousDown" : "startContinuousUp"
        send(command: cmd)
        stopTask?.cancel()
        stopTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            send(command: "stopContinuous")
        }
    }
}

extension WatchRemoteService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isPhoneReachable = WCSession.default.isReachable
        }
    }
}
