//
//  WatchRemoteService.swift
//  yprompt watch Watch App
//

import WatchConnectivity
import WatchKit
import Foundation
import Combine

struct WatchScriptInfo: Identifiable {
    let id: String
    let title: String
}

@MainActor
final class WatchRemoteService: NSObject, ObservableObject {
    static let shared = WatchRemoteService()

    enum ScrollMode { case standard, voice, timer }

    @Published var isPhoneReachable = false
    @Published var scripts: [WatchScriptInfo] = []
    @Published var currentScriptID: String? = nil
    @Published var isNotchMode: Bool = false
    @Published var scrollMode: ScrollMode = .standard
    @Published var timedMinutes: Int = 5
    @Published var timedSeconds: Int = 0

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

    func sendSpeed(_ speed: Double) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": "setSpeed", "speed": speed], replyHandler: nil, errorHandler: nil)
    }

    func startContinuous(_ command: String) {
        stopTask?.cancel()
        stopTask = nil
        send(command: command)
    }

    func stopContinuous() {
        stopTask?.cancel()
        stopTask = nil
        send(command: "stopContinuous")
    }

    func requestScripts() {
        send(command: "requestScripts")
    }

    func selectScript(id: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": "selectScript", "id": id], replyHandler: nil, errorHandler: nil)
    }

    func setNotchMode(_ enabled: Bool) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": "setNotchMode", "value": enabled], replyHandler: nil, errorHandler: nil)
    }

    func setScrollMode(_ mode: ScrollMode) {
        scrollMode = mode
        guard WCSession.default.isReachable else { return }
        switch mode {
        case .standard:
            WCSession.default.sendMessage(["command": "setVoiceScroll", "value": false], replyHandler: nil, errorHandler: nil)
            WCSession.default.sendMessage(["command": "setTimedDuration"], replyHandler: nil, errorHandler: nil)
        case .voice:
            WCSession.default.sendMessage(["command": "setVoiceScroll", "value": true], replyHandler: nil, errorHandler: nil)
            WCSession.default.sendMessage(["command": "setTimedDuration"], replyHandler: nil, errorHandler: nil)
        case .timer:
            break // Duration is committed via setTimedDuration(minutes:seconds:)
        }
    }

    func setTimedDuration(minutes: Int, seconds: Int) {
        timedMinutes = minutes
        timedSeconds = seconds
        scrollMode = .timer
        let duration = TimeInterval(minutes * 60 + seconds)
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": "setVoiceScroll", "value": false], replyHandler: nil, errorHandler: nil)
        WCSession.default.sendMessage(["command": "setTimedDuration", "duration": duration], replyHandler: nil, errorHandler: nil)
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

    // Receives messages pushed by the iPhone relay (script list updates and haptic cues).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Haptic cue: iPhone crossed a script cue point during playback
        if let cmd = message["command"] as? String, cmd == "hapticCue" {
            Task { @MainActor in
                WKInterfaceDevice.current().play(.click)
            }
            return
        }

        guard let scriptDicts = message["scripts"] as? [[String: String]] else { return }
        let parsed = scriptDicts.compactMap { dict -> WatchScriptInfo? in
            guard let id = dict["id"], let title = dict["title"] else { return nil }
            return WatchScriptInfo(id: id, title: title)
        }
        let currentID = message["currentID"] as? String
        let notchMode = message["notchMode"] as? Bool ?? false
        let voiceScrollEnabled = message["voiceScrollEnabled"] as? Bool ?? false
        let timedDuration = message["timedDuration"] as? Double

        Task { @MainActor in
            self.scripts = parsed
            self.currentScriptID = currentID
            self.isNotchMode = notchMode

            if voiceScrollEnabled {
                self.scrollMode = .voice
            } else if let duration = timedDuration, duration > 0 {
                self.scrollMode = .timer
                self.timedMinutes = Int(duration) / 60
                self.timedSeconds = Int(duration) % 60
            } else {
                self.scrollMode = .standard
            }
        }
    }
}
