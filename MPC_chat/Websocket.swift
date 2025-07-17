import Foundation
import UIKit // iOSの場合のみ必要

struct ChatMessage: Codable {
    let device: String
    let message: String
}

class WebSocketManager: ObservableObject {
    // MultipeerManager参照を保持
    private var multipeerManager: MultipeerManager?
    // MessagingManagerの参照を追加（UUID取得用）
    private weak var messagingManager: MultipeerMessagingManager?
    private var webSocketTask: URLSessionWebSocketTask?
    private let url = URL(string: "wss://mpc_websocket.keyi9029.com/ws")!
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelay: TimeInterval = 5.0
        
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
            
            // データベースを一度リセットしてから接続テストを実行
            print("[WebSocket] 初期化時にデータベースをリセットしてテストを実行します")
            MultipeerDatabaseManager.shared.resetDatabase()
            MultipeerDatabaseManager.shared.testDatabaseConnection()
        }
        
        // MessagingManagerを設定するメソッドを追加
        func setMessagingManager(_ manager: MultipeerMessagingManager) {
            self.messagingManager = manager
            print("[WebSocket] MessagingManagerが設定されました")
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
        
        // WebSocket接続時に未送信メッセージを全て送信し、全て成功したらクリア
        private func sendAllPendingMessagesIfNeeded() {
            // SQLiteデータベースから保存済みメッセージを取得
            let savedMessages = MultipeerDatabaseManager.shared.fetchAllSavedMessages()
            guard !savedMessages.isEmpty else { 
                print("[WebSocket] DB内に未送信メッセージはありません")
                return 
            }
            
            print("[WebSocket] SQLiteから未送信メッセージを送信します: \(savedMessages.count)件")
            var allSucceeded = true
            let group = DispatchGroup()
            
            for msgData in savedMessages {
                group.enter()
                let chatMessage = ChatMessage(device: msgData.senderId, message: msgData.messageText)
                guard let jsonData = try? JSONEncoder().encode(chatMessage),
                      let jsonString = String(data: jsonData, encoding: .utf8) else {
                    print("[WebSocket] JSONエンコード失敗: \(msgData.messageText)")
                    allSucceeded = false
                    group.leave()
                    continue
                }
                
                let wsMsg = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(wsMsg) { [weak self] error in
                    if let error = error {
                        print("[WebSocket] 未送信メッセージ送信失敗: \(error)")
                        allSucceeded = false
                    } else {
                        print("[WebSocket] DB送信成功: sender:\(msgData.senderId) receiver:\(msgData.receiverId) message:\(msgData.messageText)")
                    }
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                if allSucceeded {
                    print("[WebSocket] 全ての未送信メッセージ送信成功。SQLiteデータベースをクリアします。")
                    self.clearPendingMessages()
                } else {
                    print("[WebSocket] 一部未送信メッセージ送信失敗。SQLiteデータベースはクリアしません。")
                }
            }
        }
        
        // 修正版: JSONで送信 + receiverId対応
        func send(_ message: String, receiverId: String? = nil) {
            print("状態: \(webSocketTask?.state != .running)")
            if webSocketTask?.state != .running {
                print("WebSocketは接続されていません。メッセージを保存します。")
                saveMessageLocally(message, receiverId: receiverId)
            } else {
                let chatMessage = ChatMessage(device: UIDevice.current.name, message: message)
                guard let jsonData = try? JSONEncoder().encode(chatMessage),
                      let jsonString = String(data: jsonData, encoding: .utf8) else {
                    print("JSONエンコード失敗")
                    return
                }
                let msg = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(msg) { [weak self] error in
                    if let error = error {
                        print("送信エラー: \(error)")
                        self?.attemptReconnect()
                    }
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
            if let providedReceiverId = receiverId, !providedReceiverId.isEmpty {
                finalReceiverId = providedReceiverId
                print("[WebSocket] 引数で指定されたreceiverIdを使用: '\(providedReceiverId)'")
            } else if let messagingManager = messagingManager {
                let firstPeerUUID = messagingManager.getFirstPeerUUID()
                finalReceiverId = firstPeerUUID
                print("[WebSocket] MessagingManagerからUUID取得: '\(firstPeerUUID)'")
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
                        DispatchQueue.main.async {
                            self.receivedMessage = text
                            self.receivedMessages.append(text)
                        }
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

