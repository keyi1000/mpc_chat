// DBに保存されたメッセージ一覧を取得する関数
func fetchAllSavedMessages() -> [(senderId: String, receiverId: String, messageText: String, createdAt: String, localUniqueId: String)] {
    let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/messages.sqlite3")
    var db: OpaquePointer? = nil
    var result: [(String, String, String, String, String)] = []
    if sqlite3_open(dbPath, &db) != SQLITE_OK {
        print("[DB] open error (fetch)")
        return result
    }
    defer { sqlite3_close(db) }

    // テーブルがなければ作成（安全のため）
    let createTable = """
    CREATE TABLE IF NOT EXISTS messages (
      messages_id INTEGER PRIMARY KEY AUTOINCREMENT,
      sender_id TEXT NOT NULL,
      receiver_id TEXT NOT NULL,
      message_text TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      synced_at DATETIME NULL,
      local_unique_id TEXT NOT NULL,
      UNIQUE(sender_id, local_unique_id)
    );
    """
    if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
        print("[DB] create table error (fetch): \(String(cString: sqlite3_errmsg(db)))")
        return result
    }

    let query = "SELECT sender_id, receiver_id, message_text, created_at, local_unique_id FROM messages ORDER BY messages_id DESC;"
    var stmt: OpaquePointer? = nil
    if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
        while sqlite3_step(stmt) == SQLITE_ROW {
            let senderId = String(cString: sqlite3_column_text(stmt, 0))
            let receiverId = String(cString: sqlite3_column_text(stmt, 1))
            let messageText = String(cString: sqlite3_column_text(stmt, 2))
            let createdAt = String(cString: sqlite3_column_text(stmt, 3))
            let localUniqueId = String(cString: sqlite3_column_text(stmt, 4))
            result.append((senderId, receiverId, messageText, createdAt, localUniqueId))
        }
        sqlite3_finalize(stmt)
    } else {
        print("[DB] prepare error (fetch): \(String(cString: sqlite3_errmsg(db)))")
    }
    return result
}
import MultipeerConnectivity
import SQLite3

// MultipeerConnectivityを管理するクラス
class MultipeerManager: NSObject, ObservableObject {
    // DBに保存されたメッセージをログ出力する（デバッグ用）
    func printAllSavedMessagesToLog() {
        let messages = fetchAllSavedMessages()
        print("[DB] --- Saved messages ---")
        for msg in messages {
            print("[DB] sender: \(msg.senderId), receiver: \(msg.receiverId), text: \(msg.messageText), at: \(msg.createdAt), uuid: \(msg.localUniqueId)")
        }
        print("[DB] --- End ---")
    }
    // サービスの種類を定義
    private let serviceType = "mpc-chat"
    // 自身のMCPeerIDを保持
    private var myPeerId: MCPeerID
    // MCSessionを保持
    private var session: MCSession!
    // ピアを探索するためのブラウザを保持
    private var browser: MCNearbyServiceBrowser!
    // ピアを発見されるためのアドバタイザを保持
    private var advertiser: MCNearbyServiceAdvertiser!
    // WebSocketManagerのインスタンスを保持
    let manager = WebSocketManager()
    
    // 受信したメッセージを保持
    @Published var receivedMessages: [String] = []
    // 接続されているピアを保持
    @Published var connectedPeers: [MCPeerID] = []
    
    // 再接続用のタイマーと試行回数
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    
    // 再接続が必要かどうかのフラグ
    private var needsReconnect = false
    
    // UUIDを保持
    private let uuid: String = {
        if let saved = UserDefaults.standard.string(forKey: "mpc_uuid") {
            return saved
        } else {
            let newUUID = UUID().uuidString
            UserDefaults.standard.set(newUUID, forKey: "mpc_uuid")
            return newUUID
        }
    }()
    
    // 初期化処理
    override init() {
        // ユーザー名をUserDefaultsから取得し、なければデバイス名を使う
        let userName = UserDefaults.standard.string(forKey: "localUserName") ?? UIDevice.current.name
        let deviceName = userName
            .replacingOccurrences(of: " ", with: "_")
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        let truncatedName = String(deviceName.prefix(10))
        myPeerId = MCPeerID(displayName: truncatedName)
        super.init()
        
        // セッションのセットアップ
        setupSession()
    }
    
    // セッションのセットアップを行う
    private func setupSession() {
        session = MCSession(
            peer: myPeerId,
            securityIdentity: nil, // セキュリティ識別子は不要
            encryptionPreference: .required // 通信は暗号化を必須に設定
        )
        session.delegate = self // デリゲートを設定
    }
    
    // ピア探索とアドバタイジングを開始
    func start() {
        print("MultipeerManager: Starting services with peer ID: \(myPeerId.displayName)")
        
        // ブラウザの設定と開始
        browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers() // ピアの探索を開始
        
        // アドバタイザの設定と開始
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer() // ピアに自身をアナウンス
        
        // 再接続フラグをリセット
        needsReconnect = false
    }
    
    // ピア探索とアドバタイジングを停止
    func stop() {
        reconnectTimer?.invalidate() // 再接続タイマーを無効化
        
        if browser != nil {
            browser.stopBrowsingForPeers() // ピアの探索を停止
            print("MultipeerManager: Stopped browsing")
        }
        
        if advertiser != nil {
            advertiser.stopAdvertisingPeer() // アドバタイジングを停止
            print("MultipeerManager: Stopped advertising")
        }
        
        if !session.connectedPeers.isEmpty {
            session.disconnect() // セッションを切断
            print("MultipeerManager: Disconnected session")
        }
    }
    
    // デイニシャライザで停止処理を呼び出し
    deinit {
        stop()
    }
    
    // メッセージを送信
    func send(_ message: String, receiverId: String? = nil) {
        // 接続されたピアが存在し、メッセージが有効な場合のみ送信
        guard !session.connectedPeers.isEmpty, let data = message.data(using: .utf8) else {
            print("メッセージを送信できません: 接続されたピアがいないか、メッセージが無効です")
            // 接続されたピアがいない場合はメッセージをDBに保存
            if session.connectedPeers.isEmpty {
                let rid = receiverId ?? "unknown"
                saveMessageLocally(message, receiverId: rid)
                // 接続が必要な状態でまだ再接続処理が始まっていなければ開始
                if !needsReconnect {
                    needsReconnect = true
                    startReconnectProcess()
                }
            }
            return
        }
        do {
            // メッセージを接続されたすべてのピアに送信
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("MultipeerManager: Sent message to \(session.connectedPeers.count) peer(s)")
            // 送信後にDBの内容をログ出力
            printAllSavedMessagesToLog()
        } catch {
            print("MultipeerManager: Error sending message: \(error.localizedDescription)")
            // 送信に失敗した場合はローカルに保存
            let rid = receiverId ?? "unknown"
            saveMessageLocally(message, receiverId: rid)
            // 保存後にDBの内容をログ出力
            printAllSavedMessagesToLog()
        }
    }
    
    // 再接続プロセスを開始
    private func startReconnectProcess() {
        // 既に再接続タイマーが動いていれば何もしない
        guard reconnectTimer == nil else { return }
        
        reconnectAttempts = 0
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.attemptReconnect()
        }
    }
    
    // 再接続ロジック
    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("MultipeerManager: Max reconnect attempts reached")
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            return
        }
        
        // すでに接続が回復している場合は再接続を停止
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
    
    // ユーザー名変更時にMCPeerIDを即時更新するメソッド
    func updatePeerIdWithUserName() {
        // 新しいユーザー名を取得
        let userName = UserDefaults.standard.string(forKey: "localUserName") ?? UIDevice.current.name
        let deviceName = userName
            .replacingOccurrences(of: " ", with: "_")
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        let truncatedName = String(deviceName.prefix(10))
        // サービスを一旦停止
        stop()
        // 新しいPeerIDで再生成
        self.myPeerId = MCPeerID(displayName: truncatedName)
        setupSession()
        start()
    }
}

// MARK: - MCSessionDelegate
extension MultipeerManager: MCSessionDelegate {
    // ピアの状態が変更された場合の処理
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                print("MultipeerManager: Connected to peer: \(peerID.displayName)")
                self.connectedPeers = session.connectedPeers // 接続されたピアを更新
                
                // 接続成功時に再接続プロセスをクリア
                self.reconnectTimer?.invalidate()
                self.reconnectTimer = nil
                self.needsReconnect = false
                self.reconnectAttempts = 0
                
                // 保存されたメッセージがあれば送信を試みる
                self.trySendingPendingMessages()
                
            case .connecting:
                print("MultipeerManager: Connecting to peer: \(peerID.displayName)")
                
            case .notConnected:
                print("MultipeerManager: Disconnected from peer: \(peerID.displayName)")
                self.connectedPeers = session.connectedPeers // 接続ピアを更新
                
                // 接続が完全に切れた場合のみ再接続を試みる
                if self.connectedPeers.isEmpty && !self.needsReconnect {
                    self.needsReconnect = true
                    self.startReconnectProcess()
                }
                
            @unknown default:
                print("MultipeerManager: Unknown state for peer: \(peerID.displayName)")
            }
        }
    }
    
    // 保存されたメッセージの送信を試みる
    private func trySendingPendingMessages() {
        guard !session.connectedPeers.isEmpty else { return }
        
        if let pendingMessages = UserDefaults.standard.stringArray(forKey: "pendingMessages"), !pendingMessages.isEmpty {
            print("MultipeerManager: Attempting to send \(pendingMessages.count) pending messages")
            
            // ↓この行を削除します
            // UserDefaults.standard.removeObject(forKey: "pendingMessages")
            
            // ひとつずつ送信を試みる（ただし、UserDefaultsから消さない）
            for message in pendingMessages {
                send(message)
            }
        }
    }
    
    // データを受信した際の処理
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let message = String(data: data, encoding: .utf8) {
            DispatchQueue.main.async {
                // メッセージをフォーマットしてリストに追加
                let formattedMessage = "[\(peerID.displayName)]: \(message)"
                self.receivedMessages.append(formattedMessage)
                print("MultipeerManager: Received: \(formattedMessage)")
            }
        }
    }
    
    // ストリーム受信は未実装
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    
    // リソース受信開始は未実装
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    
    // リソース受信完了は未実装
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerManager: MCNearbyServiceBrowserDelegate {
    // ピアを発見した際の処理
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        print("MultipeerManager: Found peer: \(peerID.displayName)")
        
        // セッションへの招待を送信
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }
    
    // ピアを見失った際の処理
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("MultipeerManager: Lost peer: \(peerID.displayName)")
    }
    
    // ピア探索の開始に失敗した際の処理
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("MultipeerManager: Failed to start browsing: \(error.localizedDescription)")
        printDetailedError(error) // 詳細なエラー情報を表示
    }
    
    // エラー詳細を出力する関数
    private func printDetailedError(_ error: Error) {
        print("Error domain: \((error as NSError).domain)")
        print("Error code: \((error as NSError).code)")
        print("Error description: \(error.localizedDescription)")
        print("User info: \((error as NSError).userInfo)")
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension MultipeerManager: MCNearbyServiceAdvertiserDelegate {
    // ピアからの招待を受け取った際の処理
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("MultipeerManager: Invitation from: \(peerID.displayName)")
        invitationHandler(true, session) // 招待を受け入れる
    }
    
    // アドバタイジングの開始に失敗した際の処理
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("MultipeerManager: Failed to start advertising: \(error.localizedDescription)")
        printDetailedError(error) // 詳細なエラー情報を表示
    }
}

// メッセージをローカルに保存する関数
// メッセージをローカルDBに保存する関数（WebSocket未接続時のMPC送信用）
func saveMessageLocally(_ message: String, receiverId: String) {
    // sender_id, receiver_id, message_text, local_unique_id を保存
    let senderId = UserDefaults.standard.string(forKey: "localUserName") ?? UIDevice.current.name
    let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/messages.sqlite3")
    var db: OpaquePointer? = nil
    if sqlite3_open(dbPath, &db) != SQLITE_OK {
        print("[DB] open error")
        return
    }
    defer { sqlite3_close(db) }

    let createTable = """
    CREATE TABLE IF NOT EXISTS messages (
      messages_id INTEGER PRIMARY KEY AUTOINCREMENT,
      sender_id TEXT NOT NULL,
      receiver_id TEXT NOT NULL,
      message_text TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      synced_at DATETIME NULL,
      local_unique_id TEXT NOT NULL,
      UNIQUE(sender_id, local_unique_id)
    );
    """
    if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
        print("[DB] create table error")
        return
    }

    let insert = "INSERT OR IGNORE INTO messages (sender_id, receiver_id, message_text, local_unique_id) VALUES (?, ?, ?, ?);"
    var stmt: OpaquePointer? = nil
    if sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK {
        let localUniqueId = UUID().uuidString
        sqlite3_bind_text(stmt, 1, (senderId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (receiverId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (message as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (localUniqueId as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_DONE {
            print("[DB] message saved: sender=\(senderId), receiver=\(receiverId), text=\(message)")
            // 直近の保存内容を全て出力
            let all = fetchAllSavedMessages()
            print("[DB][確認] 現在DBに保存されている内容:")
            for s in all {
                print("[DB][確認] sender_id=\(s.senderId), receiver_id=\(s.receiverId), message_text=\(s.messageText), created_at=\(s.createdAt), local_unique_id=\(s.localUniqueId)")
            }
        } else {
            print("[DB] insert error")
        }
        sqlite3_finalize(stmt)
    } else {
        print("[DB] prepare error")
    }
}
