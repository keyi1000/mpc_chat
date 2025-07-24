import Foundation
import UIKit // iOSの場合のみ必要

// .envファイルから環境変数を取得する簡易関数
func loadEnvValue(for key: String) -> String? {
    guard let envPath = Bundle.main.path(forResource: ".env", ofType: nil),
          let envString = try? String(contentsOfFile: envPath) else { return nil }
    for line in envString.components(separatedBy: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

struct ChatMessage: Codable {
    let senderId: String     // 送信者UUID
    let receiverId: String   // 受信者UUID
    let message: String      // メッセージ内容
    let timestamp: String?   // 送信時刻（オプション）
    
    // 後方互換性のため旧形式も保持
    var device: String { return senderId }
}

class WebSocketManager: ObservableObject {
    // MultipeerManager参照を保持
    private var multipeerManager: MultipeerManager?
    // MessagingManagerの参照を追加（UUID取得用）
    private weak var messagingManager: MultipeerMessagingManager?
    private var webSocketTask: URLSessionWebSocketTask?
    private let url: URL = {
        if let wsUrlString = loadEnvValue(for: "WEBSOCKET_URL"), let wsUrl = URL(string: wsUrlString) {
            return wsUrl
        }
        // デフォルト値（.envが読めない場合）
        return URL(string: "wss://mpc_websocket.keyi9029.com/ws")!
    }()
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelay: TimeInterval = 5.0
    
    // 送信重複防止フラグ
    private var isSending: Bool = false
    private let sendingLock = NSLock()
        
        @Published var receivedMessage: String = ""
        @Published var receivedMessages: [String] = []
        @Published var isConnected: Bool = false
        
        private var connectionCheckTimer: Timer?
        private var reconnectTimer: Timer?
        
        // ユーザー名を設定・取得できるプロパティ
        var userName: String {
            get {
                UserDefaults.standard.string(forKey: "localUserName") ?? UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            }
            set {
                UserDefaults.standard.set(newValue, forKey: "localUserName")
            }
        }
        
        // ユーザーID（送信者ID）
        var myId: String {
            return userName
        }
        
        // イニシャライザでMultipeerManagerを受け取る
        init(multipeerManager: MultipeerManager? = nil) {
            self.multipeerManager = multipeerManager
            print("[WebSocket] 初期化開始 - multipeerManager: \(multipeerManager != nil)")
            
            // MultipeerManagerからMessagingManagerの参照を取得
            if let multipeerManager = multipeerManager {
                self.messagingManager = multipeerManager.getMessagingManager()
                print("[WebSocket] 初期化時にMessagingManagerの参照を設定しました")
                print("[WebSocket] 初期化後の確認 - messagingManager: \(self.messagingManager != nil)")
            } else {
                print("[WebSocket] 警告: MultipeerManagerがnilのため、MessagingManagerを設定できませんでした")
            }
        }
        
        // MessagingManagerを設定するメソッドを追加
        func setMessagingManager(_ manager: MultipeerMessagingManager) {
            self.messagingManager = manager
            print("[WebSocket] MessagingManagerが設定されました")
            print("[WebSocket] 設定後の確認 - messagingManager: \(messagingManager != nil)")
            
            // 設定直後にUUID状況をテスト
            let peerUUIDMap = manager.getAllPeerUUIDs()
            let firstPeerUUID = manager.getFirstPeerUUID()
            print("[WebSocket] 設定直後のpeerUUIDMap: \(peerUUIDMap)")
            print("[WebSocket] 設定直後のfirstPeerUUID: '\(firstPeerUUID)'")
        }
        
        // MessagingManagerの参照を強制的に再設定するメソッド
        func forceSetMessagingManager(_ multipeerManager: MultipeerManager?) {
            if let multipeerManager = multipeerManager {
                self.messagingManager = multipeerManager.getMessagingManager()
                print("[WebSocket] forceSetMessagingManager: MessagingManagerを強制再設定しました")
                let peerUUIDMap = self.messagingManager?.getAllPeerUUIDs()
                let firstPeerUUID = self.messagingManager?.getFirstPeerUUID()
                print("[WebSocket] 再設定後のpeerUUIDMap: \(peerUUIDMap ?? [:])")
                print("[WebSocket] 再設定後のfirstPeerUUID: '\(firstPeerUUID ?? "nil")'")
            } else {
                print("[WebSocket] forceSetMessagingManager: MultipeerManagerがnilのため設定できませんでした")
            }
        }
        
        func isConnectedNow() -> Bool {
            return isConnected
        }
        
        func connect() {
            disconnect()
            print("[WebSocket] WebSocketサーバーに接続中: \(url.absoluteString)")
            let request = URLRequest(url: url, timeoutInterval: 10)
            webSocketTask = URLSession.shared.webSocketTask(with: request)
            webSocketTask?.resume()
            isConnected = true
            reconnectAttempts = 0
            receive()
            startConnectionMonitor()
            startAutoReconnectLoop()
            sendAllPendingMessagesIfNeeded()
        }
        
        // WebSocket接続時に未送信メッセージを全て送信し、送信成功したもののみ個別削除
        private func sendAllPendingMessagesIfNeeded() {
            // SQLiteデータベースから保存済みメッセージを取得（IDも含む）
            let savedMessagesWithId = MultipeerDatabaseManager.shared.fetchAllSavedMessagesWithId()
            guard !savedMessagesWithId.isEmpty else { 
                print("[WebSocket] DB内に未送信メッセージはありません")
                return 
            }
            
            print("[WebSocket] SQLiteから未送信メッセージを送信します: \(savedMessagesWithId.count)件")
            let group = DispatchGroup()
            var successfulMessageIds: [Int] = []
            let successfulMessageIdsLock = NSLock()
            
            for msgData in savedMessagesWithId {
                group.enter()
                // DBから取り出したデータの詳細をログ出力
                print("[WebSocket] DB取得データ詳細: ID=\(msgData.id), sender='\(msgData.senderId)', receiver='\(msgData.receiverId)', message='\(msgData.messageText)'")
                
                // receiver_idが空またはunknownの場合の対処
                let finalReceiverId: String
                if msgData.receiverId.isEmpty || msgData.receiverId == "unknown" {
                    // MessagingManagerから最新のUUIDを取得
                    if let messagingManager = messagingManager {
                        // MessagingManagerの状態を詳細確認
                        let peerUUIDMap = messagingManager.getAllPeerUUIDs()
                        print("[WebSocket] DB送信時 - MessagingManager peerUUIDMap状態: \(peerUUIDMap)")
                        
                        // ConnectionManagerの接続状態も確認
                        if let multipeerManager = multipeerManager {
                            let connectedPeers = multipeerManager.connectedPeers
                            print("[WebSocket] DB送信時 - MultipeerConnectivity接続状態: \(connectedPeers.count)台接続中")
                            if connectedPeers.isEmpty {
                                print("[WebSocket] DB送信時 - MultipeerConnectivityが接続されていないため、スキップします")
                                group.leave()
                                continue
                            } else {
                                print("[WebSocket] DB送信時 - 接続済みピア: \(connectedPeers.map { $0.displayName })")
                            }
                        }
                        
                        finalReceiverId = messagingManager.getFirstPeerUUID()
                        print("[WebSocket] receiver_idが空/unknownのため、MessagingManagerから取得: '\(finalReceiverId)'")
                        
                        // 取得したUUIDも無効な場合はスキップ
                        if finalReceiverId == "unknown" || finalReceiverId.isEmpty {
                            print("[WebSocket] 有効なreceiverIdが取得できないため、メッセージID \(msgData.id) をスキップします")
                            group.leave()
                            continue
                        }
                    } else {
                        print("[WebSocket] MessagingManagerが利用できないため、メッセージID \(msgData.id) をスキップします")
                        group.leave()
                        continue
                    }
                } else {
                    finalReceiverId = msgData.receiverId
                    print("[WebSocket] DBのreceiver_idをそのまま使用: '\(finalReceiverId)'")
                }
                
                // DBから取り出したデータをそのまま使用
                let chatMessage = ChatMessage(
                    senderId: msgData.senderId,
                    receiverId: finalReceiverId, 
                    message: msgData.messageText,
                    timestamp: msgData.createdAt
                )
                guard let jsonData = try? JSONEncoder().encode(chatMessage),
                      let jsonString = String(data: jsonData, encoding: .utf8) else {
                    print("[WebSocket] JSONエンコード失敗: ID \(msgData.id) - \(msgData.messageText)")
                    group.leave()
                    continue
                }
                
                print("[WebSocket] 送信JSON: \(jsonString)")
                let wsMsg = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(wsMsg) { [weak self] error in
                    if let error = error {
                        print("[WebSocket] 未送信メッセージ送信失敗: ID \(msgData.id) - \(error)")
                    } else {
                        print("[WebSocket] DB送信成功: ID \(msgData.id) sender:\(msgData.senderId) receiver:\(finalReceiverId) message:\(msgData.messageText)")
                        // 送信成功したメッセージIDを記録
                        successfulMessageIdsLock.lock()
                        successfulMessageIds.append(msgData.id)
                        successfulMessageIdsLock.unlock()
                    }
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                // 送信成功したメッセージのみ個別削除
                print("[WebSocket] 送信完了: 成功 \(successfulMessageIds.count)件 / 全体 \(savedMessagesWithId.count)件")
                for messageId in successfulMessageIds {
                    let deleteSuccess = MultipeerDatabaseManager.shared.deleteMessage(withId: messageId)
                    if deleteSuccess {
                        print("[WebSocket] DB個別削除成功: ID \(messageId)")
                    } else {
                        print("[WebSocket] DB個別削除失敗: ID \(messageId)")
                    }
                }
                
                if successfulMessageIds.count == savedMessagesWithId.count {
                    print("[WebSocket] 全メッセージ送信成功・削除完了")
                } else {
                    let failedCount = savedMessagesWithId.count - successfulMessageIds.count
                    print("[WebSocket] \(failedCount)件の送信失敗メッセージがDBに残存")
                }
            }
        }
        
        // 修正版: JSONで送信 + receiverId対応 + 重複防止
        func send(_ message: String, receiverId: String? = nil) {
            // 送信中チェック
            sendingLock.lock()
            if isSending {
                sendingLock.unlock()
                print("[WebSocket] 既に送信処理中のため、重複送信を防止しました")
                return
            }
            isSending = true
            sendingLock.unlock()
            
            defer {
                sendingLock.lock()
                isSending = false
                sendingLock.unlock()
            }
            
            print("[WebSocket] send()開始 - receiverId: '\(receiverId ?? "nil")'")
            print("[WebSocket] WebSocket状態: \(webSocketTask?.state != .running)")
            print("[WebSocket] messagingManager存在確認: \(messagingManager != nil)")
            print("[WebSocket] multipeerManager存在確認: \(multipeerManager != nil)")
            
            // MessagingManagerの参照を送信前に強制的に確認・再設定
            if messagingManager == nil {
                print("[WebSocket] 警告: MessagingManagerがnilです。強制再設定を試みます...")
                forceSetMessagingManager(multipeerManager)
            }
            
            if webSocketTask?.state != .running {
                print("WebSocketは接続されていません。メッセージを保存します。")
                saveMessageLocally(message, receiverId: receiverId)
                return
            }
            
            // 自分のUUIDを取得
            let myUUID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            
            // 受信者IDを決定
            let finalReceiverId = getFinalReceiverId(receiverId: receiverId)
            
            // receiverIdが有効でない場合は送信を中止
            if finalReceiverId == "unknown" || finalReceiverId.isEmpty {
                print("[WebSocket] 送信中止: 有効なreceiverIdが取得できませんでした (receiverId: '\(finalReceiverId)')")
                print("[WebSocket] UUID交換が完了していない可能性があります。メッセージをDBに保存します。")
                saveMessageLocally(message, receiverId: receiverId)
                return
            }
            
            // メッセージを送信
            sendMessageDirectly(message: message, senderId: myUUID, receiverId: finalReceiverId)
        }
        
        // 受信者IDを決定するシンプルなメソッド
        private func getFinalReceiverId(receiverId: String?) -> String {
            // 1. 引数で指定されたreceiverIdがある場合
            if let providedReceiverId = receiverId, !providedReceiverId.isEmpty && providedReceiverId != "unknown" {
                print("[WebSocket] 引数で指定されたreceiverIdを使用: '\(providedReceiverId)'")
                return providedReceiverId
            }
            
            // 2. MessagingManagerからUUIDを取得
            guard let messagingManager = messagingManager else {
                print("[WebSocket] MessagingManagerが設定されていないため'unknown'を使用")
                return "unknown"
            }
            
            print("[WebSocket] MessagingManagerからUUID取得を試みます")
            let peerUUIDMap = messagingManager.getAllPeerUUIDs()
            print("[WebSocket] peerUUIDMap状態: \(peerUUIDMap)")
            
            // 接続状態を確認
            if let multipeerManager = multipeerManager {
                let connectedPeers = multipeerManager.connectedPeers
                print("[WebSocket] 接続状態: \(connectedPeers.count)台接続中")
                if connectedPeers.isEmpty {
                    print("[WebSocket] 接続がないため'unknown'を使用")
                    return "unknown"
                }
            }
            
            // UUIDを取得
            let peerUUID = messagingManager.getFirstPeerUUID()
            print("[WebSocket] 取得したUUID: '\(peerUUID)'")
            
            // exchangedPeerUUIDも確認
            if peerUUID == "unknown" || peerUUID.isEmpty {
                let exchangedUUID = messagingManager.getExchangedPeerUUID()
                print("[WebSocket] exchangedPeerUUID確認: '\(exchangedUUID)'")
                if !exchangedUUID.isEmpty && exchangedUUID != "unknown" {
                    return exchangedUUID
                }
            }
            
            return peerUUID
        }
        
        // メッセージを直接送信するメソッド
        private func sendMessageDirectly(message: String, senderId: String, receiverId: String) {
            print("[WebSocket] 最終決定 - sender: '\(senderId)', receiver: '\(receiverId)'")
            
            let chatMessage = ChatMessage(
                senderId: senderId,
                receiverId: receiverId,
                message: message,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            
            guard let jsonData = try? JSONEncoder().encode(chatMessage),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                print("JSONエンコード失敗")
                return
            }
            
            print("[WebSocket] 送信JSON: \(jsonString)")
            let msg = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(msg) { [weak self] error in
                if let error = error {
                    print("送信エラー: \(error)")
                    self?.saveMessageLocally(message, receiverId: receiverId)
                    self?.attemptReconnect()
                } else {
                    print("[WebSocket] 送信成功: sender:\(senderId) receiver:\(receiverId) message:\(message)")
                    print("[WebSocket] 送信成功のためDBには保存しません")
                }
            }
        }
        
        // 送信者ID・受信者IDも保存するバージョン（SQLiteデータベースに保存）
        func saveMessageLocally(_ message: String, receiverId: String? = nil) {
            print("[WebSocket] saveMessageLocally開始 - 受信したreceiverIdパラメータ: '\(receiverId ?? "nil")'")
            
            // 自分のUUIDを取得
            let myUUID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            
            // 受信者IDを決定：1) 引数で指定されたもの、2) MessagingManagerから取得、3) "unknown"
            let finalReceiverId: String
            if let providedReceiverId = receiverId, !providedReceiverId.isEmpty && providedReceiverId != "unknown" {
                finalReceiverId = providedReceiverId
                print("[WebSocket] 引数で指定されたreceiverIdを使用: '\(providedReceiverId)'")
            } else if let messagingManager = messagingManager {
                // MessagingManagerの状態を詳細確認
                let peerUUIDMap = messagingManager.getAllPeerUUIDs()
                print("[WebSocket] saveMessageLocally - MessagingManager peerUUIDMap状態: \(peerUUIDMap)")
                
                // ConnectionManagerの接続状態も確認
                if let multipeerManager = multipeerManager {
                    let connectedPeers = multipeerManager.connectedPeers
                    print("[WebSocket] saveMessageLocally - MultipeerConnectivity接続状態: \(connectedPeers.count)台接続中")
                    if connectedPeers.isEmpty {
                        print("[WebSocket] saveMessageLocally - MultipeerConnectivityが接続されていないため、receiverIdはunknownに設定")
                    } else {
                        print("[WebSocket] saveMessageLocally - 接続済みピア: \(connectedPeers.map { $0.displayName })")
                    }
                }
                
                let firstPeerUUID = messagingManager.getFirstPeerUUID()
                if firstPeerUUID != "unknown" && !firstPeerUUID.isEmpty {
                    finalReceiverId = firstPeerUUID
                    print("[WebSocket] MessagingManagerからUUID取得: '\(firstPeerUUID)'")
                } else {
                    finalReceiverId = "unknown"
                    print("[WebSocket] MessagingManagerからのUUIDが無効のため'unknown'を使用")
                }
            } else {
                finalReceiverId = "unknown"
                print("[WebSocket] MessagingManagerが設定されていないため'unknown'を使用")
            }
            
            print("[WebSocket] 保存前 - message: \(message), receiverId: \(finalReceiverId), senderId: \(myUUID)")
            MultipeerDatabaseManager.shared.saveMessageLocally(message, receiverId: finalReceiverId, senderId: myUUID)
            print("【WebSocket送信失敗】メッセージをSQLiteデータベースに保存しました")
            
            // 保存後の確認
            let savedMessages = MultipeerDatabaseManager.shared.fetchAllSavedMessages()
            print("[WebSocket] 保存後確認 - DB内メッセージ数: \(savedMessages.count)")
            // 最後に保存されたメッセージの詳細も表示
            if let lastMessage = savedMessages.first {
                print("[WebSocket] 最新保存メッセージ: sender='\(lastMessage.senderId)', receiver='\(lastMessage.receiverId)', message='\(lastMessage.messageText)'")
            }
        }
        
        public func getPendingMessages() -> [String] {
            // SQLiteデータベースから保存済みメッセージを取得
            let messages = MultipeerDatabaseManager.shared.fetchAllSavedMessages()
            return messages.map { "\($0.messageText) (送信先: \($0.receiverId))" }
        }
        
        public func clearPendingMessages() {
            // SQLiteデータベースのメッセージをクリア
            MultipeerDatabaseManager.shared.clearAllMessages()
            print("【SQLiteデータベース】全メッセージを削除しました")
        }
        
        private func receive() {
            webSocketTask?.receive { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    print("受信エラー: \(error)")
                case .success(let message):
                    switch message {
                    case .string(let text):
                        print("[WebSocket] メッセージを受信しましたが、画面表示はしません: \(text)")
                        // 受信したメッセージは画面に表示せず、ログ出力のみ
                        // DispatchQueue.main.async {
                        //     self.receivedMessage = text
                        //     self.receivedMessages.append(text)
                        // }
                    case .data(let data):
                        print("データ受信: \(data)")
                    @unknown default:
                        break
                    }
                    self.receive()
                }
            }
        }
        
        func disconnect() {
            isConnected = false
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            stopConnectionMonitor()
            startAutoReconnectLoop() // 切断時も再接続ループを維持
        }
        
        private func attemptReconnect() {
            guard reconnectAttempts < maxReconnectAttempts else {
                print("[WebSocket] 最大再接続回数(\(maxReconnectAttempts))に達しました。再接続を停止します。")
                stopAutoReconnectLoop()
                return
            }
            reconnectAttempts += 1
            print("[WebSocket] 再接続を試みます（\(reconnectAttempts)/\(maxReconnectAttempts)回目）...")
            DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
                self?.connect()
            }
        }
        
        func startConnectionMonitor() {
            connectionCheckTimer?.invalidate()
            connectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let actuallyConnected = self.webSocketTask?.state == .running
                print("[WebSocketMonitor] state: \(self.webSocketTask?.state.rawValue ?? -1), isConnected: \(self.isConnected), actuallyConnected: \(actuallyConnected)")
                if self.isConnected != actuallyConnected {
                    DispatchQueue.main.async {
                        self.isConnected = actuallyConnected
                    }
                }
            }
        }
        
        func stopConnectionMonitor() {
            connectionCheckTimer?.invalidate()
            connectionCheckTimer = nil
        }
        
        func startAutoReconnectLoop() {
            reconnectTimer?.invalidate()
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if !self.isConnectedNow() && self.reconnectAttempts < self.maxReconnectAttempts {
                    print("[AutoReconnect] WebSocket未接続のため再接続を試みます (試行回数: \(self.reconnectAttempts)/\(self.maxReconnectAttempts))")
                    self.connect()
                } else if self.reconnectAttempts >= self.maxReconnectAttempts {
                    print("[AutoReconnect] 最大再接続回数に達したため、自動再接続を停止します")
                    self.stopAutoReconnectLoop()
                }
            }
        }
        
        func stopAutoReconnectLoop() {
            reconnectTimer?.invalidate()
            reconnectTimer = nil
        }
        
        // 近くのデバイスID一覧を取得する
        func nearbyDeviceIds() -> [String] {
            return multipeerManager?.connectedPeers.map { $0.displayName } ?? []
        }
    }

