import Foundation
import MultipeerConnectivity
import SQLite3

// MARK: - 統合MultipeerManager（レガシー互換性用）
/**
 * MultipeerManager
 * 
 * 既存のコードとの互換性を保ちながら、新しく分離されたマネージャーを統合するファサードクラス
 * 責任範囲:
 * - 各専門マネージャーの初期化と連携設定
 * - 既存APIとの互換性維持
 * - UIバインディング用のプロパティ公開
 * - レガシーコードからの段階的移行サポート
 * 
 * 使用される専門マネージャー:
 * - MultipeerConnectionManager: 接続・セッション管理
 * - MultipeerMessagingManager: メッセージ送受信
 * - MultipeerDatabaseManager: データ永続化
 * - WebSocketManager: WebSocket通信（既存）
 */
class MultipeerManager: ObservableObject {
    // MARK: - Manager Dependencies
    /// 接続・セッション管理専門マネージャー
    private let connectionManager = MultipeerConnectionManager()
    /// メッセージ送受信専門マネージャー
    private let messagingManager = MultipeerMessagingManager()
    /// WebSocket通信マネージャー（既存のまま保持）
    let manager = WebSocketManager()
    
    // MARK: - Published Properties (UI Binding)
    /// 接続されているピアのリスト（UI表示用）
    @Published var connectedPeers: [MCPeerID] = []
    /// 受信したメッセージのリスト（UI表示用）
    @Published var receivedMessages: [String] = []
    
    // MARK: - Initialization
    /**
     * 初期化処理
     * 
     * 各マネージャー間の相互参照を設定し、
     * 状態変更の監視バインディングを設定する
     */
    init() {
        // マネージャー間の相互参照を設定
        connectionManager.setMessagingManager(messagingManager)
        messagingManager.setConnectionManager(connectionManager)
        // WebSocketManagerにMessagingManagerの参照を設定
        manager.setMessagingManager(messagingManager)
        
        // 各マネージャーの状態変更をこのクラスのPublishedプロパティにバインド
        connectionManager.$connectedPeers
            .assign(to: &$connectedPeers)
        messagingManager.$receivedMessages
            .assign(to: &$receivedMessages)
    }
    
    // MARK: - Connection Management (Delegation)
    /**
     * MultipeerConnectivityサービスの開始
     * 接続マネージャーに委譲
     */
    func start() {
        connectionManager.start()
    }
    
    /**
     * MultipeerConnectivityサービスの停止
     * 接続マネージャーに委譲
     */
    func stop() {
        connectionManager.stop()
    }
    
    /**
     * ユーザー名変更に伴うピアID更新
     * 接続マネージャーに委譲
     */
    func updatePeerIdWithUserName() {
        connectionManager.updatePeerIdWithUserName()
    }
    
    // MARK: - Messaging (Delegation)
    /**
     * メッセージ送信（レガシー互換性）
     * - Parameter message: 送信するメッセージ
     * - Parameter receiverId: 受信者ID（オプション）
     * 
     * メッセージングマネージャーに委譲
     */
    func send(_ message: String, receiverId: String? = nil) {
        messagingManager.sendMessage(message, receiverId: receiverId)
    }
    
    // MARK: - Data Management (Delegation)
    /**
     * メッセージ保存・取得（レガシー互換性）
     * データ永続化マネージャーに委譲
     */
    func printAllSavedMessagesToLog() {
        MultipeerDatabaseManager.shared.printAllSavedMessagesToLog()
    }
}

// MARK: - Legacy Compatibility Functions
/**
 * レガシー互換性のためのグローバル関数
 * 
 * 既存のコードで直接呼び出されている関数群を維持し、
 * 新しいマネージャーに委譲する
 */

/**
 * メッセージをローカルに保存（レガシー互換性）
 * - Parameter message: 保存するメッセージ
 * - Parameter receiverId: 受信者ID
 */
func saveMessageLocally(_ message: String, receiverId: String) {
    MultipeerDatabaseManager.shared.saveMessageLocally(message, receiverId: receiverId)
}

/**
 * 保存されたメッセージを全て取得（レガシー互換性）
 * - Returns: メッセージのタプル配列
 */
func fetchAllSavedMessages() -> [(senderId: String, receiverId: String, messageText: String, createdAt: String)] {
    return MultipeerDatabaseManager.shared.fetchAllSavedMessages()
}
