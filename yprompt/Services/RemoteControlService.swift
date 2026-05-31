//
//  RemoteControlService.swift
//  yprompt
//

#if !os(watchOS)
import MultipeerConnectivity
import Foundation
import Combine
#if !os(macOS)
import UIKit
#endif

// MARK: - ScriptInfo

struct ScriptInfo: Codable, Identifiable {
    let id: UUID
    let title: String
}

// MARK: - RemoteControlCommand

enum RemoteControlCommand: Codable {
    case startContinuousDown
    case startContinuousUp
    case stopContinuous
    case togglePlayPause
    case reset
    case setSpeed(Double)
    case selectScript(UUID)
    case setNotchMode(Bool)

    // Used by WatchSessionRelay to decode Watch-originated commands (no associated values).
    init?(rawValue: String) {
        switch rawValue {
        case "startContinuousDown": self = .startContinuousDown
        case "startContinuousUp":   self = .startContinuousUp
        case "stopContinuous":      self = .stopContinuous
        case "togglePlayPause":     self = .togglePlayPause
        case "reset":               self = .reset
        default:                    return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case type, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "startContinuousDown": self = .startContinuousDown
        case "startContinuousUp":   self = .startContinuousUp
        case "stopContinuous":      self = .stopContinuous
        case "togglePlayPause":     self = .togglePlayPause
        case "reset":               self = .reset
        case "setSpeed":            self = .setSpeed(try c.decode(Double.self, forKey: .payload))
        case "selectScript":        self = .selectScript(try c.decode(UUID.self, forKey: .payload))
        case "setNotchMode":        self = .setNotchMode(try c.decode(Bool.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown command")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .startContinuousDown: try c.encode("startContinuousDown", forKey: .type)
        case .startContinuousUp:   try c.encode("startContinuousUp",   forKey: .type)
        case .stopContinuous:      try c.encode("stopContinuous",       forKey: .type)
        case .togglePlayPause:     try c.encode("togglePlayPause",      forKey: .type)
        case .reset:               try c.encode("reset",                forKey: .type)
        case .setSpeed(let speed):
            try c.encode("setSpeed", forKey: .type)
            try c.encode(speed, forKey: .payload)
        case .selectScript(let id):
            try c.encode("selectScript", forKey: .type)
            try c.encode(id, forKey: .payload)
        case .setNotchMode(let isNotch):
            try c.encode("setNotchMode", forKey: .type)
            try c.encode(isNotch, forKey: .payload)
        }
    }
}

// MARK: - RemoteMessage (bidirectional envelope)

enum RemoteMessage: Codable {
    case command(RemoteControlCommand)
    /// Sent Mac → iOS: script list, currently active script ID, and notch-mode state.
    case scriptList([ScriptInfo], UUID?, Bool)

    private enum CodingKeys: String, CodingKey { case kind, command, scripts, currentID, notchMode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "command":
            self = .command(try c.decode(RemoteControlCommand.self, forKey: .command))
        case "scriptList":
            self = .scriptList(
                try c.decode([ScriptInfo].self, forKey: .scripts),
                try c.decodeIfPresent(UUID.self, forKey: .currentID),
                (try? c.decode(Bool.self, forKey: .notchMode)) ?? false
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown message kind")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .command(let cmd):
            try c.encode("command", forKey: .kind)
            try c.encode(cmd, forKey: .command)
        case .scriptList(let scripts, let currentID, let notchMode):
            try c.encode("scriptList", forKey: .kind)
            try c.encode(scripts, forKey: .scripts)
            try c.encodeIfPresent(currentID, forKey: .currentID)
            try c.encode(notchMode, forKey: .notchMode)
        }
    }
}

// MARK: - RemoteControlService

@MainActor
final class RemoteControlService: NSObject, ObservableObject {
    static let shared = RemoteControlService()
    static let serviceType = "yprmpt-ctrl"

    @Published var connectedPeers: [MCPeerID] = []
    @Published var discoveredPeers: [MCPeerID] = []
    @Published var isConnected: Bool = false

    /// Script list received from the Mac (iOS remote side).
    @Published var availableScripts: [ScriptInfo] = []
    /// Currently active script ID received from the Mac (iOS remote side).
    @Published var currentRemoteScriptID: UUID? = nil
    /// Whether the Mac is currently in notch mode (iOS remote side).
    @Published var remoteNotchMode: Bool = false

    var onCommandReceived: ((RemoteControlCommand) -> Void)?
    var onLastPeerDisconnected: (() -> Void)?
    var onPeerConnected: ((MCPeerID) -> Void)?

    private let myPeerID: MCPeerID
    private lazy var session: MCSession = {
        let s = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private override init() {
        #if os(macOS)
        myPeerID = MCPeerID(displayName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        #else
        myPeerID = MCPeerID(displayName: UIDevice.current.name)
        #endif
        super.init()
    }

    // MARK: - Mac (Host) Side

    func startAdvertising() {
        guard advertiser == nil else { return }
        let adv = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
    }

    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
    }

    // MARK: - iPhone (Remote) Side

    func startBrowsing() {
        guard browser == nil else { return }
        let brw = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        brw.delegate = self
        brw.startBrowsingForPeers()
        browser = brw
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        discoveredPeers = []
    }

    func connect(to peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }

    func disconnect() {
        session.disconnect()
        connectedPeers = []
        isConnected = false
        availableScripts = []
        currentRemoteScriptID = nil
        remoteNotchMode = false
    }

    // MARK: - Sending

    func send(command: RemoteControlCommand) {
        guard !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(RemoteMessage.command(command)) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func sendScriptList(_ scripts: [ScriptInfo], currentID: UUID?, notchMode: Bool, to peer: MCPeerID) {
        guard let data = try? JSONEncoder().encode(RemoteMessage.scriptList(scripts, currentID, notchMode)) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }
}

// MARK: - MCSessionDelegate

extension RemoteControlService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                if !self.connectedPeers.contains(peerID) { self.connectedPeers.append(peerID) }
                self.isConnected = !self.connectedPeers.isEmpty
                self.onPeerConnected?(peerID)
            case .notConnected:
                self.connectedPeers.removeAll { $0 == peerID }
                self.isConnected = !self.connectedPeers.isEmpty
                if self.connectedPeers.isEmpty { self.onLastPeerDisconnected?() }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(RemoteMessage.self, from: data) else { return }
        Task { @MainActor in
            switch message {
            case .command(let command):
                self.onCommandReceived?(command)
            case .scriptList(let scripts, let currentID, let notchMode):
                self.availableScripts = scripts
                self.currentRemoteScriptID = currentID
                self.remoteNotchMode = notchMode
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension RemoteControlService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            invitationHandler(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}
}

// MARK: - MCNearbyServiceBrowserDelegate

extension RemoteControlService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !self.discoveredPeers.contains(peerID) { self.discoveredPeers.append(peerID) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredPeers.removeAll { $0 == peerID }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}
}
#endif
