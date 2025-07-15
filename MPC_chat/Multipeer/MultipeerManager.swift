import Foundation
import MultipeerConnectivity
import SQLite3

// MARK: - 統合MultipeerManager（レガシー互換性用）
class MultipeerManager: ObservableObject {
    private let connectionManager = MultipeerConnectionManager()
    let manager = WebSocketManager()
    
    // 接続管理のプロパティを公開
    @Published var connectedPeers: [MCPeerID] = []
    @Published var receivedMessages: [String] = []
    
    init() {
        // 接続管理の状態を監視
        connectionManager.$connectedPeers
            .assign(to: &$connectedPeers)
        connectionManager.$receivedMessages
            .assign(to: &$receivedMessages)
    }
    
    // 接続管理のメソッドを委譲
    func start() {
        connectionManager.start()
    }
    
    func stop() {
        connectionManager.stop()
    }
    
    func updatePeerIdWithUserName() {
        connectionManager.updatePeerIdWithUserName()
    }
    
    // メッセージ送信（レガシー互換性）
    func send(_ message: String, receiverId: String? = nil) {
        connectionManager.sendMessage(message, receiverId: receiverId)
    }
    
    // メッセージ保存・取得（レガシー互換性）
    func printAllSavedMessagesToLog() {
        MultipeerMessageManager.shared.printAllSavedMessagesToLog()
    }
}

// レガシー互換性のためのグローバル関数
func saveMessageLocally(_ message: String, receiverId: String) {
    MultipeerMessageManager.shared.saveMessageLocally(message, receiverId: receiverId)
}

func fetchAllSavedMessages() -> [(senderId: String, receiverId: String, messageText: String, createdAt: String, localUniqueId: String)] {
    return MultipeerMessageManager.shared.fetchAllSavedMessages()
}
