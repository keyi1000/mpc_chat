import Foundation
import UIKit // iOSの場合のみ必要

struct ChatMessage: Codable {
    let device: String
    let message: String
}

class WebSocketManager: ObservableObject {
    // MultipeerManager参照を保持
    private var multipeerManager: MultipeerManager?
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
    }
    
    func isConnectedNow() -> Bool {
        return isConnected
    }
    
    func connect() {
        disconnect()
        print("WebSocketに接続中...")
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
        let pending = getPendingMessages()
        guard !pending.isEmpty else { return }
        print("[WebSocket] 未送信メッセージを送信します: \(pending.count)件")
        var allSucceeded = true
        let group = DispatchGroup()
        for msg in pending {
            group.enter()
            let chatMessage = ChatMessage(device: UIDevice.current.name, message: msg)
            guard let jsonData = try? JSONEncoder().encode(chatMessage),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                print("[WebSocket] JSONエンコード失敗: \(msg)")
                allSucceeded = false
                group.leave()
                continue
            }
            let wsMsg = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(wsMsg) { [weak self] error in
                if let error = error {
                    print("[WebSocket] 未送信メッセージ送信失敗: \(error)")
                    allSucceeded = false
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if allSucceeded {
                print("[WebSocket] 全ての未送信メッセージ送信成功。クリアします。")
                self.clearPendingMessages()
            } else {
                print("[WebSocket] 一部未送信メッセージ送信失敗。クリアしません。")
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
    
// 送信者ID・受信者IDも保存するバージョン
func saveMessageLocally(_ message: String, receiverId: String? = nil) {
    // JSON型で保存: [ { message, date, senderId, receiverId } ]
    let now = ISO8601DateFormatter().string(from: Date())
    let senderId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device-id"
    let receiver = receiverId ?? ""
    let dict: [String: String] = [
        "message": message,
        "date": now,
        "senderId": senderId,
        "receiverId": receiver
    ]
    var pendingArray = UserDefaults.standard.array(forKey: "pendingMessages") as? [[String: String]] ?? []
    pendingArray.append(dict)
    UserDefaults.standard.set(pendingArray, forKey: "pendingMessages")
    // 保存済みメッセージ一覧を出力
    let savedMessages = UserDefaults.standard.array(forKey: "pendingMessages") as? [[String: String]] ?? []
    print("【保存済みメッセージ一覧】")
    for (index, msgDict) in savedMessages.enumerated() {
        let text = msgDict["message"] ?? ""
        let date = msgDict["date"] ?? ""
        let sender = msgDict["senderId"] ?? ""
        let receiver = msgDict["receiverId"] ?? ""
        print("[\(index + 1)] \(text) (\(date)) sender=\(sender) receiver=\(receiver)")
    }
    print("【保存済みメッセージ一覧】", savedMessages)
}
    
    public func getPendingMessages() -> [String] {
        return UserDefaults.standard.stringArray(forKey: "pendingMessages") ?? []
    }
    
    public func clearPendingMessages() {
        UserDefaults.standard.removeObject(forKey: "pendingMessages")
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
            print("最大再接続回数に達しました")
            return
        }
        reconnectAttempts += 1
        print("再接続を試みます（\(reconnectAttempts)回目）...")
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
            if !self.isConnectedNow() {
                print("[AutoReconnect] WebSocket未接続のため再接続を試みます")
                self.connect()
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
