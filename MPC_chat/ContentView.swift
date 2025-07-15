import SwiftUI
import MultipeerConnectivity

// メインのビュー
struct ContentView: View {
    // MultipeerManagerをStateObjectとして保持
    @StateObject private var multipeerManager = MultipeerManager()
    // WebSocketManagerをmultipeerManager付きで初期化
    @StateObject private var webSocketManager: WebSocketManager
    // 送信するメッセージを格納する状態変数
    @State private var messageToSend: String = ""
    @State private var showPendingMessages = false
    @State private var pendingMessages: [String] = []
    @State private var username: String = UserDefaults.standard.string(forKey: "localUserName") ?? ""
    @State private var receiverId: String = ""
    @State private var showUserNameDialog = false
    
    // イニシャライザでwebSocketManagerにmultipeerManagerを渡す
    init() {
        let multipeer = MultipeerManager()
        _multipeerManager = StateObject(wrappedValue: multipeer)
        _webSocketManager = StateObject(wrappedValue: WebSocketManager(multipeerManager: multipeer))
    }
    
    var body: some View {
        VStack {
            // ヘッダー表示とユーザー名表示
            HStack {
                Text("Chat App")
                    .font(.headline)
                Spacer()
                Button("ユーザー名: \(webSocketManager.userName)") {
                    showUserNameDialog = true
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
            .padding(.horizontal)
            
            // 受信したメッセージをリスト形式で表示
            List(multipeerManager.receivedMessages, id: \.self) { message in
                Text(message)
            }
            List(webSocketManager.receivedMessages, id: \.self) { message in
                Text(message)
            }
            
            // 近くのデバイス一覧から宛先を選択
            HStack {
                Text("宛先選択:")
                    .font(.caption)
                Picker("宛先", selection: $receiverId) {
                    Text("選択してください").tag("")
                    ForEach(webSocketManager.nearbyDeviceIds(), id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)
            
            // メッセージ入力フィールドと送信ボタン
            HStack {
                TextField("メッセージを入力", text: $messageToSend)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button("Send") {
                    multipeerManager.send(messageToSend)
                    webSocketManager.send(messageToSend)
                    messageToSend = ""
                }
                .disabled(messageToSend.isEmpty || receiverId.isEmpty || (multipeerManager.connectedPeers.isEmpty && webSocketManager.isConnectedNow() == false))
            }
            .padding()
            
            // 接続状態を表示
            VStack(spacing: 4) {
                Text("Connected Peers: \(multipeerManager.connectedPeers.count)")
                    .font(.caption)
                    .foregroundColor(multipeerManager.connectedPeers.isEmpty ? .red : .green)
                
                Text(webSocketManager.isConnectedNow() ? "WebSocket接続中" : "WebSocket未接続（再接続中...）")
                    .font(.caption)
                    .foregroundColor(webSocketManager.isConnectedNow() ? .blue : .orange)
            }
            
            // 未送信メッセージ表示ボタン
            Button("未送信メッセージを見る") {
                pendingMessages = webSocketManager.getPendingMessages()
                showPendingMessages = true
            }
            .padding(.top)
        }
        .sheet(isPresented: $showUserNameDialog) {
            VStack(spacing: 20) {
                Text("ユーザー名設定")
                    .font(.headline)
                TextField("ユーザー名を入力", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                HStack {
                    Button("キャンセル") {
                        showUserNameDialog = false
                    }
                    .foregroundColor(.red)
                    
                    Button("保存") {
                        webSocketManager.userName = username
                        showUserNameDialog = false
                    }
                    .disabled(username.isEmpty)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showPendingMessages) {
            VStack {
                Text("未送信メッセージ一覧")
                    .font(.headline)
                if pendingMessages.isEmpty {
                    Text("未送信メッセージはありません")
                        .foregroundColor(.gray)
                } else {
                    List(pendingMessages, id: \.self) { msg in
                        Text(msg)
                    }
                    Button("全て消す") {
                        webSocketManager.clearPendingMessages()
                        pendingMessages = []
                    }
                    .foregroundColor(.red)
                    .padding()
                }
                Button("閉じる") {
                    showPendingMessages = false
                }
                .padding(.top)
            }
            .padding()
        }
        .onAppear {
            multipeerManager.start()
            webSocketManager.connect()
            username = webSocketManager.userName // 現在のユーザー名を取得
        }
        .onDisappear {
            multipeerManager.stop()
            webSocketManager.disconnect()
        }
    }
}
