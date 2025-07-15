import Foundation
import MultipeerConnectivity

// MARK: - メッセージ送受信管理
/**
 * MultipeerMessagingManager
 * 
 * MultipeerConnectivityを使用したメッセージの送受信を専門的に管理するクラス
 * 責任範囲:
 * - メッセージの送信処理
 * - メッセージの受信処理とフォーマット
 * - ACK（受信確認）メッセージの送受信
 * - 保留中メッセージの再送処理
 * - 受信メッセージリストの状態管理
 */
class MultipeerMessagingManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    /// 受信したメッセージのリスト（UI表示用）
    @Published var receivedMessages: [String] = []
    
    // MARK: - Private Properties
    /// このデバイス固有のUUID（ACK処理で使用）
    private let uuid: String = {
        if let saved = UserDefaults.standard.string(forKey: "mpc_uuid") {
            return saved
        } else {
            let newUUID = UUID().uuidString
            UserDefaults.standard.set(newUUID, forKey: "mpc_uuid")
            return newUUID
        }
    }()
    
    /// 接続マネージャーへの弱参照（メッセージ送信にセッション情報が必要）
    private weak var connectionManager: MultipeerConnectionManager?
    
    // MARK: - Initialization
    override init() {
        super.init()
    }
    
    // MARK: - Public Methods
    /**
     * 接続マネージャーを設定
     * - Parameter manager: MultipeerConnectionManagerのインスタンス
     */
    func setConnectionManager(_ manager: MultipeerConnectionManager) {
        self.connectionManager = manager
    }
    
    /**
     * メッセージ送信機能
     * - Parameter message: 送信するメッセージ内容
     * - Parameter receiverId: 受信者ID（オプション、未指定時は"unknown"）
     * 
     * 処理フロー:
     * 1. 接続状態とセッションの有効性を確認
     * 2. 接続されたピアがいない場合は、メッセージを保存して再接続を試行
     * 3. メッセージをデータに変換してMultipeerConnectivity経由で送信
     * 4. 送信失敗時はローカルに保存
     */
    func sendMessage(_ message: String, receiverId: String? = nil) {
        // 接続マネージャーが設定されているかチェック
        guard let connectionManager = connectionManager else {
            print("MultipeerMessagingManager: Connection manager not set")
            return
        }
        
        // セッションの取得と接続状態の確認
        guard let session = connectionManager.getSession(),
              !session.connectedPeers.isEmpty,
              let data = message.data(using: .utf8) else {
            print("メッセージを送信できません: 接続されたピアがいないか、メッセージが無効です")
            
            // 接続がない場合はメッセージを保存し、再接続を試行
            if let session = connectionManager.getSession(), session.connectedPeers.isEmpty {
                let rid = receiverId ?? "unknown"
                MultipeerMessageManager.shared.saveMessageLocally(message, receiverId: rid)
                connectionManager.triggerReconnectIfNeeded()
            }
            return
        }
        
        // メッセージ送信の実行
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("MultipeerMessagingManager: Sent message to \(session.connectedPeers.count) peer(s)")
            MultipeerMessageManager.shared.printAllSavedMessagesToLog()
        } catch {
            // 送信失敗時の処理：ローカル保存とログ出力
            print("MultipeerMessagingManager: Error sending message: \(error.localizedDescription)")
            let rid = receiverId ?? "unknown"
            MultipeerMessageManager.shared.saveMessageLocally(message, receiverId: rid)
            MultipeerMessageManager.shared.printAllSavedMessagesToLog()
        }
    }
    
    /**
     * 保留中のメッセージの送信を試みる
     * 
     * 接続が復旧した際に、UserDefaultsに保存された未送信メッセージを
     * 順次送信する処理。ConnectionManagerから接続確立時に呼び出される。
     */
    func trySendingPendingMessages() {
        // 接続状態の確認
        guard let connectionManager = connectionManager,
              let session = connectionManager.getSession(),
              !session.connectedPeers.isEmpty else { return }
        
        // UserDefaultsから保留メッセージを取得
        if let pendingMessages = UserDefaults.standard.stringArray(forKey: "pendingMessages"), !pendingMessages.isEmpty {
            print("MultipeerMessagingManager: Attempting to send \(pendingMessages.count) pending messages")
            // 各メッセージを順次送信
            for message in pendingMessages {
                sendMessage(message)
            }
        }
    }
    
    /**
     * メッセージ受信処理のメインハンドラ
     * - Parameter data: 受信したデータ
     * - Parameter peerID: 送信者のピアID
     * - Parameter session: MultipeerConnectivityセッション
     * 
     * 処理フロー:
     * 1. データを文字列に変換
     * 2. ACKメッセージかどうかを判定
     * 3. ACKの場合は専用処理、通常メッセージの場合はACKを返送
     * 4. 受信メッセージリストに追加
     */
    func handleReceivedData(_ data: Data, fromPeer peerID: MCPeerID, session: MCSession) {
        if let message = String(data: data, encoding: .utf8) {
            // ACKメッセージかどうかの判定と処理
            if message.hasPrefix("ACK:") {
                handleAckMessage(message)
                return
            }
            
            // 通常のメッセージ受信処理：ACKを返送
            sendAckMessage(for: message, to: peerID, session: session)
            
            // UIスレッドで受信メッセージリストを更新
            DispatchQueue.main.async {
                let formattedMessage = "[\(peerID.displayName)]: \(message)"
                self.receivedMessages.append(formattedMessage)
                print("MultipeerMessagingManager: Received: \(formattedMessage)")
            }
        }
    }
    
    // MARK: - Private Methods
    /**
     * ACKメッセージの処理
     * - Parameter message: "ACK:"プレフィックス付きのメッセージ
     * 
     * ACKメッセージは送信確認として使用され、受信時に
     * 元のメッセージをローカルDBに保存する
     */
    private func handleAckMessage(_ message: String) {
        let senderMessage = message.replacingOccurrences(of: "ACK:", with: "")
        let receiverUniqueId = UserDefaults.standard.string(forKey: "mpc_uuid") ?? "unknown-uuid"
        MultipeerMessageManager.shared.saveMessageLocally(senderMessage, receiverId: receiverUniqueId)
        print("[MPC] ACK受信: senderMessage=\(senderMessage), receiverId(uuid)=\(receiverUniqueId)")
    }
    
    /**
     * ACKメッセージの送信
     * - Parameter message: 元のメッセージ内容
     * - Parameter peerID: 送信先のピア
     * - Parameter session: MultipeerConnectivityセッション
     * 
     * 通常のメッセージを受信した際に、送信者に対して
     * 受信確認（ACK）を返送する
     */
    private func sendAckMessage(for message: String, to peerID: MCPeerID, session: MCSession) {
        let myUniqueId = self.uuid
        if let ackData = ("ACK:" + message).data(using: .utf8) {
            do {
                try session.send(ackData, toPeers: [peerID], with: .reliable)
                print("[MPC] ACK送信: uuid=\(myUniqueId) -> \(peerID.displayName) for message=\(message)")
            } catch {
                print("[MPC] ACK送信失敗: \(error)")
            }
        }
    }
}
