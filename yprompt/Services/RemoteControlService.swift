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

enum RemoteControlCommand: String, Codable {
    case startContinuousDown
    case startContinuousUp
    case stopContinuous
    case togglePlayPause
    case reset
}

@MainActor
final class RemoteControlService: NSObject, ObservableObject {
    static let shared = RemoteControlService()
    static let serviceType = "yprmpt-ctrl"

    @Published var connectedPeers: [MCPeerID] = []
    @Published var discoveredPeers: [MCPeerID] = []
    @Published var isConnected: Bool = false

    var onCommandReceived: ((RemoteControlCommand) -> Void)?
    var onLastPeerDisconnected: (() -> Void)?

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
    }

    func send(command: RemoteControlCommand) {
        guard !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(command) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
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
        guard let command = try? JSONDecoder().decode(RemoteControlCommand.self, from: data) else { return }
        Task { @MainActor in
            self.onCommandReceived?(command)
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
