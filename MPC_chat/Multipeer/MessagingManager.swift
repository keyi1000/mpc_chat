import Foundation
import MultipeerConnectivity
import UIKit

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
    /// 相手から受け取ったUUID
    private var exchangedPeerUUID: String = ""
    
    /// 接続中のピアのUUIDマップ（PeerID名 → UUID）
    private var peerUUIDMap: [String: String] = [:]
    
    /// このデバイス固有のUUID（端末固定）
    private let uuid: String = {
        // デバイス固有のUUIDを取得（アプリ削除まで永続）
        if let deviceUUID = UIDevice.current.identifierForVendor?.uuidString {
            return deviceUUID
        } else {
            print("デバイス固有のUUIDを取得できませんでした")
            return "UUID_ERROR_404"
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
     * 相手のUUIDをリクエストするメソッド
     */
    func requestPeerUUID(for peerID: MCPeerID) {
        let uuidRequestMessage = "UUID_REQUEST:\(self.uuid)"
        sendSimpleMessage(uuidRequestMessage, to: [peerID])
        print("【UUID_REQUEST送信】\(peerID.displayName)に自分のUUIDを送信: \(self.uuid)")
    }

    /**
     * UUIDを受信した際の処理
     */
    func handleReceivedUUID(_ uuid: String, from peerID: MCPeerID) {
        self.exchangedPeerUUID = uuid
        // peerUUIDMapにも保存
        self.peerUUIDMap[peerID.displayName] = uuid
        print("受信側相手から受け取ったUUID: \(uuid)")
        print("【UUID交換完了】自分のUUID: \(self.uuid) | 相手のUUID: \(uuid)")
        print("【PeerUUIDMap更新】\(peerID.displayName) -> \(uuid)")
    }
    
    /**
     * メッセージ送信機能
     * - Parameter message: 送信するメッセージ内容
     * - Parameter receiverId: 受信者ID（オプション、未指定時は接続中の全ピアのUUIDを使用）
     * 
     * 処理フロー:
     * 1. 接続状態とセッションの有効性を確認
     * 2. UUID交換が未完了の場合は、まずUUID交換を実行
     * 3. 接続されたピアがいない場合は、メッセージを保存して再接続を試行
     * 4. メッセージをデータに変換してMultipeerConnectivity経由で送信
     * 5. 送信失敗時はローカルに保存
     */
    func sendMessage(_ message: String, receiverId: String? = nil) {
        // UUID交換状態をログ出力（デバッグ用）
        print("【メッセージ送信開始】exchangedPeerUUID状態: '\(exchangedPeerUUID)'")
        print("【メッセージ送信開始】peerUUIDMap状態: \(peerUUIDMap)")
        
        // 接続マネージャーが設定されているかチェック
        guard let connectionManager = connectionManager else {
            print("コネクションの相手が設定されていません")
            return
        }
        
        // セッションの取得と接続状態の確認
        guard let session = connectionManager.getSession(),
              !session.connectedPeers.isEmpty,
              let data = message.data(using: .utf8) else {
            print("メッセージを送信できません: 接続されたピアがいないか、メッセージが無効です")
            // 接続がない場合はメッセージをDBに保存
            let rid = getReceiverUUID(for: receiverId)
            print("【DB保存デバッグ】receiverId: \(receiverId ?? "nil"), 最終的なrid: '\(rid)'")
            MultipeerDatabaseManager.shared.saveMessageLocally(message, receiverId: rid, senderId: self.uuid)
            return
        }
        
        // UUID交換が未完了の場合は、まずUUID交換を実行してからメッセージを送信
        if shouldRequestUUIDExchange(for: session.connectedPeers) {
            print("【メッセージ送信前】UUID交換が必要です。UUID交換を実行します")
            for peer in session.connectedPeers {
                if peerUUIDMap[peer.displayName] == nil {
                    requestPeerUUID(for: peer)
                }
            }
            // UUID交換完了を待ってからメッセージを送信
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.sendActualMessage(message, to: session, receiverId: receiverId)
            }
            return
        }
        
        // UUID交換済みの場合は直接メッセージ送信を実行
        sendActualMessage(message, to: session, receiverId: receiverId)
    }
    
    /**
     * 実際のメッセージ送信処理
     * - Parameter message: 送信するメッセージ
     * - Parameter session: MCSession
     * - Parameter receiverId: 受信者ID
     */
    private func sendActualMessage(_ message: String, to session: MCSession, receiverId: String?) {
        guard let data = message.data(using: .utf8) else {
            print("メッセージのデータ変換に失敗しました")
            return
        }
        
        // 受信者IDを決定（peerUUIDMapを優先使用）
        let actualReceiverId = getReceiverUUID(for: receiverId)
        
        // メッセージ送信の実行
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("メッセージを送信しました: 接続されたピア数 = \(session.connectedPeers.count)")
            print("【送信詳細】sender_uuid: \(self.uuid), receiver_uuid: \(actualReceiverId), message: \(message)")
            // 送信成功時もDBに保存
            MultipeerDatabaseManager.shared.saveMessageLocally(message, receiverId: actualReceiverId, senderId: self.uuid)
            MultipeerDatabaseManager.shared.printAllSavedMessagesToLog()
        } catch {
            // 送信失敗時の処理：ローカル保存とログ出力
            print("メッセージ送信エラー: \(error.localizedDescription)")
            print("【DB保存デバッグ】receiverId: \(receiverId ?? "nil"), actualReceiverId: '\(actualReceiverId)'")
            MultipeerDatabaseManager.shared.saveMessageLocally(message, receiverId: actualReceiverId, senderId: self.uuid)
            MultipeerDatabaseManager.shared.printAllSavedMessagesToLog()
        }
    }
    
    /**
     * 保留中のメッセージの送信を試みる
     * 
     * 接続が復旧した際に、SQLiteデータベースに保存された未送信メッセージを
     * 順次送信する処理。ConnectionManagerから接続確立時に呼び出される。
     */
    func trySendingPendingMessages() {
        // 接続状態の確認
        guard let connectionManager = connectionManager,
              let session = connectionManager.getSession(),
              !session.connectedPeers.isEmpty else { return }
        
        // SQLiteデータベースから保留メッセージを取得
        let savedMessages = MultipeerDatabaseManager.shared.fetchAllSavedMessages()
        if !savedMessages.isEmpty {
            print("【DB保留メッセージ送信】データベースから\(savedMessages.count)件のメッセージを再送信します")
            // 各メッセージを順次送信（既にDBに保存済みなので、重複保存を避ける）
            for msgData in savedMessages {
                // 直接MultipeerConnectivity経由で送信（DB保存はスキップ）
                sendDirectMessage(msgData.messageText, to: session)
            }
            
            // 全ての再送信完了後、データベースをクリア
            MultipeerDatabaseManager.shared.clearAllMessages()
            print("【DB保留メッセージ送信】再送信完了、データベースをクリアしました")
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
     * 2. UUIDメッセージかどうかを判定
     * 3. 通常メッセージの場合は受信メッセージリストに追加
     */
    func handleReceivedData(_ data: Data, fromPeer peerID: MCPeerID, session: MCSession) {
        if let message = String(data: data, encoding: .utf8) {
            // UUIDメッセージの処理
            if message.hasPrefix("UUID_REQUEST:") {
                let peerUUID = message.replacingOccurrences(of: "UUID_REQUEST:", with: "")
                handleReceivedUUID(peerUUID, from: peerID)
                // UUIDレスポンスを送信
                let responseMessage = "UUID_RESPONSE:\(self.uuid)"
                sendSimpleMessage(responseMessage, to: [peerID])
                // UUID交換状況を表示
                print("【UUID_REQUEST受信】相手からUUID交換要求を受信")
                printUUIDStatus()
                return
            }
            
            if message.hasPrefix("UUID_RESPONSE:") {
                let peerUUID = message.replacingOccurrences(of: "UUID_RESPONSE:", with: "")
                handleReceivedUUID(peerUUID, from: peerID)
                // UUID交換状況を表示
                print("【UUID_RESPONSE受信】相手からUUID交換応答を受信")
                printUUIDStatus()
                return
            }
            
            // UIスレッドで受信メッセージリストを更新
            DispatchQueue.main.async {
                let formattedMessage = "[\(peerID.displayName)]: \(message)"
                self.receivedMessages.append(formattedMessage)
                print("受信側相手から受け取ったメッセージ: \(formattedMessage)")
                
                // 受信したメッセージもデータベースに保存（相手がsender、自分がreceiver）
                let senderUUID = self.peerUUIDMap[peerID.displayName] ?? self.exchangedPeerUUID
                if !senderUUID.isEmpty {
                    MultipeerDatabaseManager.shared.saveMessageLocally(message, receiverId: self.uuid, senderId: senderUUID)
                    print("【受信メッセージ保存】sender_uuid: \(senderUUID), receiver_uuid: \(self.uuid), message: \(message)")
                } else {
                    print("【受信メッセージ保存スキップ】相手のUUIDが未取得のため保存を見合わせます")
                }
            }
        }
    }
    
    // MARK: - Private Methods

    /**
     * 保存済みメッセージを全て削除する（デバッグ・リセット用）
     */
    func clearAllSavedMessages() {
        MultipeerDatabaseManager.shared.clearAllMessages()
        print("【SQLiteデータベース】全削除しました")
    }
    /**
     * 簡単なメッセージ送信
     * - Parameter message: 送信するメッセージ
     * - Parameter peers: 送信先のピア配列
     */
    private func sendSimpleMessage(_ message: String, to peers: [MCPeerID]) {
        guard let connectionManager = connectionManager,
              let session = connectionManager.getSession(),
              let data = message.data(using: .utf8) else { return }
        
        do {
            try session.send(data, toPeers: peers, with: .reliable)
            print("送信: \(message) to \(peers.count) ピア")
        } catch {
            print("送信失敗: \(error)")
        }
    }
    
    /**
     * ダイレクトメッセージ送信（DB保存なし）
     * - Parameter message: 送信するメッセージ
     * - Parameter session: MCSession
     * 
     * 注意: このメソッドはDB保存を行わない、再送信専用
     */
    private func sendDirectMessage(_ message: String, to session: MCSession) {
        guard let data = message.data(using: .utf8) else {
            print("メッセージのデータ変換に失敗しました")
            return
        }
        
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("【DB再送信】メッセージを直接送信しました: \(message)")
        } catch {
            print("【DB再送信失敗】メッセージ送信エラー: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helper Methods
    
    /**
     * UUID交換が必要かどうかをチェック
     * - Parameter peers: 接続中のピアリスト
     * - Returns: UUID交換が必要な場合はtrue
     */
    private func shouldRequestUUIDExchange(for peers: [MCPeerID]) -> Bool {
        for peer in peers {
            if peerUUIDMap[peer.displayName] == nil {
                return true
            }
        }
        return false
    }
    
    /**
     * 受信者UUIDを決定する
     * - Parameter receiverId: 指定された受信者ID（オプション）
     * - Returns: 最適な受信者UUID
     */
    private func getReceiverUUID(for receiverId: String?) -> String {
        // 1. 明示的に指定されたreceiverIdがある場合はそれを使用
        if let receiverId = receiverId, !receiverId.isEmpty {
            return receiverId
        }
        
        // 2. peerUUIDMapから最初のUUIDを取得
        if let firstPeerUUID = peerUUIDMap.values.first {
            return firstPeerUUID
        }
        
        // 3. exchangedPeerUUIDがある場合はそれを使用
        if !exchangedPeerUUID.isEmpty {
            return exchangedPeerUUID
        }
        
        // 4. どれもない場合は"unknown"
        return "unknown"
    }

    // MARK: - Public UUID Methods
    /**
     * 取得したUUIDを返す（表示用）
     */
    func getExchangedPeerUUID() -> String {
        return exchangedPeerUUID
    }
    
    /**
     * 自分のUUIDを返す（表示用）
     */
    func getMyUUID() -> String {
        return uuid
    }
    
    /**
     * UUID交換状況をログに表示
     */
    func printUUIDStatus() {
        print("【UUID状況】自分: \(uuid)")
        if exchangedPeerUUID.isEmpty {
            print("【UUID状況】相手: 未取得")
        } else {
            print("【UUID状況】相手: \(exchangedPeerUUID)")
        }
    }
    
    /**
     * 接続状態リセット（新しい接続の際に呼び出し）
     */
    func resetUUIDExchangeState() {
        exchangedPeerUUID = ""
        peerUUIDMap.removeAll()
        print("【UUID状態リセット】新しい接続のため状態をクリア")
    }
    
    /**
     * 接続中の全てのピアのUUIDを取得（WebSocket用）
     * - Returns: ピア名とUUIDのマップ
     */
    func getAllPeerUUIDs() -> [String: String] {
        return peerUUIDMap
    }
    
    /**
     * 最初に見つかったピアのUUIDを取得（WebSocket用）
     * - Returns: 最初のピアのUUID、存在しない場合は"unknown"
     */
    func getFirstPeerUUID() -> String {
        return peerUUIDMap.values.first ?? (exchangedPeerUUID.isEmpty ? "unknown" : exchangedPeerUUID)
    }
}
