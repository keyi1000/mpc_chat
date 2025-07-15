import Foundation
import MultipeerConnectivity

// MARK: - MultipeerConnectivity接続管理
class MultipeerConnectionManager: NSObject, ObservableObject {
    private let serviceType = "mpc-chat"
    private var myPeerId: MCPeerID
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser!
    private var advertiser: MCNearbyServiceAdvertiser!
    @Published var connectedPeers: [MCPeerID] = []
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var needsReconnect = false
    private let uuid: String = {
        if let saved = UserDefaults.standard.string(forKey: "mpc_uuid") {
            return saved
        } else {
            let newUUID = UUID().uuidString
            UserDefaults.standard.set(newUUID, forKey: "mpc_uuid")
            return newUUID
        }
    }()

    @Published var receivedMessages: [String] = []

    override init() {
        let userName = UserDefaults.standard.string(forKey: "localUserName") ?? UIDevice.current.name
        let deviceName = userName
            .replacingOccurrences(of: " ", with: "_")
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        let truncatedName = String(deviceName.prefix(10))
        myPeerId = MCPeerID(displayName: truncatedName)
        super.init()
        setupSession()
    }
    
    private func setupSession() {
        session = MCSession(
            peer: myPeerId,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
    }
    
    func start() {
        print("MultipeerManager: Starting services with peer ID: \(myPeerId.displayName)")
        browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        needsReconnect = false
    }
    
    func stop() {
        reconnectTimer?.invalidate()
        if browser != nil {
            browser.stopBrowsingForPeers()
            print("MultipeerManager: Stopped browsing")
        }
        if advertiser != nil {
            advertiser.stopAdvertisingPeer()
            print("MultipeerManager: Stopped advertising")
        }
        if !session.connectedPeers.isEmpty {
            session.disconnect()
            print("MultipeerManager: Disconnected session")
        }
    }
    
    deinit {
        stop()
    }
    
    private func startReconnectProcess() {
        guard reconnectTimer == nil else { return }
        reconnectAttempts = 0
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.attemptReconnect()
        }
    }
    
    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("MultipeerManager: Max reconnect attempts reached")
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            return
        }
        if !session.connectedPeers.isEmpty {
            print("MultipeerManager: Connection already restored")
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            needsReconnect = false
            reconnectAttempts = 0
            return
        }
        reconnectAttempts += 1
        print("MultipeerManager: Attempting reconnect \(reconnectAttempts)/\(maxReconnectAttempts)")
        stop()
        setupSession()
        start()
    }
    
    func updatePeerIdWithUserName() {
        let userName = UserDefaults.standard.string(forKey: "localUserName") ?? UIDevice.current.name
        let deviceName = userName
            .replacingOccurrences(of: " ", with: "_")
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        let truncatedName = String(deviceName.prefix(10))
        stop()
        self.myPeerId = MCPeerID(displayName: truncatedName)
        setupSession()
        start()
    }
    
    // メッセージ送信機能
    func sendMessage(_ message: String, receiverId: String? = nil) {
        guard !session.connectedPeers.isEmpty, let data = message.data(using: .utf8) else {
            print("メッセージを送信できません: 接続されたピアがいないか、メッセージが無効です")
            if session.connectedPeers.isEmpty {
                let rid = receiverId ?? "unknown"
                MultipeerMessageManager.shared.saveMessageLocally(message, receiverId: rid)
                if !needsReconnect {
                    needsReconnect = true
                    startReconnectProcess()
                }
            }
            return
        }
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("MultipeerManager: Sent message to \(session.connectedPeers.count) peer(s)")
            MultipeerMessageManager.shared.printAllSavedMessagesToLog()
        } catch {
            print("MultipeerManager: Error sending message: \(error.localizedDescription)")
            let rid = receiverId ?? "unknown"
            MultipeerMessageManager.shared.saveMessageLocally(message, receiverId: rid)
            MultipeerMessageManager.shared.printAllSavedMessagesToLog()
        }
    }
    
    private func trySendingPendingMessages() {
        guard !session.connectedPeers.isEmpty else { return }
        if let pendingMessages = UserDefaults.standard.stringArray(forKey: "pendingMessages"), !pendingMessages.isEmpty {
            print("MultipeerManager: Attempting to send \(pendingMessages.count) pending messages")
            for message in pendingMessages {
                sendMessage(message)
            }
        }
    }
}

// MARK: - MCSessionDelegate
extension MultipeerConnectionManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                print("MultipeerManager: Connected to peer: \(peerID.displayName)")
                self.connectedPeers = session.connectedPeers
                self.reconnectTimer?.invalidate()
                self.reconnectTimer = nil
                self.needsReconnect = false
                self.reconnectAttempts = 0
                self.trySendingPendingMessages()
                
            case .connecting:
                print("MultipeerManager: Connecting to peer: \(peerID.displayName)")
                
            case .notConnected:
                print("MultipeerManager: Disconnected from peer: \(peerID.displayName)")
                self.connectedPeers = session.connectedPeers
                if self.connectedPeers.isEmpty && !self.needsReconnect {
                    self.needsReconnect = true
                    self.startReconnectProcess()
                }
                
            @unknown default:
                print("MultipeerManager: Unknown state for peer: \(peerID.displayName)")
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let message = String(data: data, encoding: .utf8) {
            if message.hasPrefix("ACK:") {
                let senderMessage = message.replacingOccurrences(of: "ACK:", with: "")
                let receiverUniqueId = UserDefaults.standard.string(forKey: "mpc_uuid") ?? "unknown-uuid"
                MultipeerMessageManager.shared.saveMessageLocally(senderMessage, receiverId: receiverUniqueId)
                print("[MPC] ACK受信: senderMessage=\(senderMessage), receiverId(uuid)=\(receiverUniqueId)")
                return
            }
            let myUniqueId = self.uuid
            if let ackData = ("ACK:" + message).data(using: .utf8) {
                do {
                    try session.send(ackData, toPeers: [peerID], with: .reliable)
                    print("[MPC] ACK送信: uuid=\(myUniqueId) -> \(peerID.displayName) for message=\(message)")
                } catch {
                    print("[MPC] ACK送信失敗: \(error)")
                }
            }
            DispatchQueue.main.async {
                let formattedMessage = "[\(peerID.displayName)]: \(message)"
                self.receivedMessages.append(formattedMessage)
                print("MultipeerManager: Received: \(formattedMessage)")
            }
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerConnectionManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        print("MultipeerManager: Found peer: \(peerID.displayName)")
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("MultipeerManager: Lost peer: \(peerID.displayName)")
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("MultipeerManager: Failed to start browsing: \(error.localizedDescription)")
        printDetailedError(error)
    }
    
    private func printDetailedError(_ error: Error) {
        print("Error domain: \((error as NSError).domain)")
        print("Error code: \((error as NSError).code)")
        print("Error description: \(error.localizedDescription)")
        print("User info: \((error as NSError).userInfo)")
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension MultipeerConnectionManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("MultipeerManager: Invitation from: \(peerID.displayName)")
        invitationHandler(true, session)
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("MultipeerManager: Failed to start advertising: \(error.localizedDescription)")
        printDetailedError(error)
    }
}
