import Foundation
import MultipeerConnectivity
import UIKit

// MARK: - MultipeerConnectivity接続管理
/**
 * MultipeerConnectionManager
 * 
 * MultipeerConnectivityの接続・セッション管理を専門的に行うクラス
 * 責任範囲:
 * - ピアの発見と接続管理
 * - セッションの開始・停止・再接続
 * - ネットワーク状態の監視
 * - ピア情報の管理
 * - デリゲート処理（セッション、ブラウザ、アドバタイザ）
 */
class MultipeerConnectionManager: NSObject, ObservableObject {
    // MARK: - Constants
    /// MultipeerConnectivityで使用するサービスタイプ
    private let serviceType = "mpc-chat"
    /// 再接続の最大試行回数
    private let maxReconnectAttempts = 5
    
    // MARK: - Core Properties
    /// このデバイスのピアID
    private var myPeerId: MCPeerID
    /// MultipeerConnectivityセッション
    private var session: MCSession!
    /// 近隣ピアの検索サービス
    private var browser: MCNearbyServiceBrowser!
    /// このデバイスの広告サービス
    private var advertiser: MCNearbyServiceAdvertiser!
    
    // MARK: - Published Properties
    /// 接続されているピアのリスト（UI表示用）
    @Published var connectedPeers: [MCPeerID] = []
    
    // MARK: - Reconnection Properties
    /// 再接続処理用のタイマー
    private var reconnectTimer: Timer?
    /// 現在の再接続試行回数
    private var reconnectAttempts = 0
    /// 再接続が必要かどうかのフラグ
    private var needsReconnect = false

    // MARK: - Manager References
    /// メッセージング管理への弱参照
    private weak var messagingManager: MultipeerMessagingManager?

    // MARK: - Initialization
    /**
     * 初期化処理
     * 
     * ユーザー名からピアIDを生成し、セッションを設定する
     * ピア名は10文字に制限され、特殊文字は除去される
     */
    override init() {
        // ユーザー名の取得と加工
        let userName = UserDefaults.standard.string(forKey: "localUserName") ?? UIDevice.current.name
        let deviceName = userName
            .replacingOccurrences(of: " ", with: "_")  // スペースをアンダースコアに変換
            .folding(options: .diacriticInsensitive, locale: .current)  // アクセント記号を除去
            .components(separatedBy: CharacterSet.alphanumerics.inverted)  // 英数字以外を除去
            .joined(separator: "_")
        let truncatedName = String(deviceName.prefix(10))  // 10文字に制限
        
        // ピアIDの作成
        myPeerId = MCPeerID(displayName: truncatedName)
        super.init()
        setupSession()
    }
    
    // MARK: - Public Methods
    /**
     * メッセージングマネージャーを設定
     * - Parameter manager: MultipeerMessagingManagerのインスタンス
     */
    func setMessagingManager(_ manager: MultipeerMessagingManager) {
        self.messagingManager = manager
    }
    
    /**
     * セッションへのアクセスを提供（メッセージング用）
     * - Returns: 現在のMCSessionインスタンス、またはnil
     */
    func getSession() -> MCSession? {
        return session
    }
    
    /**
     * 再接続トリガー（メッセージング側から呼び出し用）
     * 
     * メッセージ送信失敗時などに、メッセージングマネージャーから
     * 再接続処理を開始するために呼び出される
     */
    func triggerReconnectIfNeeded() {
        if !needsReconnect {
            needsReconnect = true
            startReconnectProcess()
        }
    }
    
    // MARK: - Session Management
    /**
     * セッションの初期設定
     * 
     * MCSessionを作成し、デリゲートを設定する
     * 暗号化は必須に設定される
     */
    private func setupSession() {
        session = MCSession(
            peer: myPeerId,
            securityIdentity: nil,
            encryptionPreference: .required  // 暗号化を必須に設定
        )
        session.delegate = self
    }
    
    /**
     * MultipeerConnectivityサービスの開始
     * 
     * ブラウザ（ピア検索）とアドバタイザ（自身の広告）の両方を開始する
     * これにより、他のデバイスを発見し、同時に他のデバイスから発見される
     */
    func start() {
        print("MultipeerManager: Starting services with peer ID: \(myPeerId.displayName)")
        
        // ピア検索サービスの開始
        browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        
        // 自身の広告サービスの開始
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        
        needsReconnect = false
    }
    
    /**
     * MultipeerConnectivityサービスの停止
     * 
     * すべてのサービス（ブラウザ、アドバタイザ、セッション）を停止し、
     * 再接続タイマーもクリアする
     */
    func stop() {
        // 再接続タイマーの停止
        reconnectTimer?.invalidate()
        
        // ブラウザの停止
        if browser != nil {
            browser.stopBrowsingForPeers()
            print("MultipeerManager: Stopped browsing")
        }
        
        // アドバタイザの停止
        if advertiser != nil {
            advertiser.stopAdvertisingPeer()
            print("MultipeerManager: Stopped advertising")
        }
        
        // セッションの切断
        if !session.connectedPeers.isEmpty {
            session.disconnect()
            print("MultipeerManager: Disconnected session")
        }
    }
    
    /**
     * デストラクタ
     * インスタンス破棄時にサービスを確実に停止する
     */
    deinit {
        stop()
    }
    
    // MARK: - Reconnection Management
    /**
     * 再接続プロセスの開始
     * 
     * 5秒間隔で再接続を試行するタイマーを開始する
     * 既にタイマーが動作中の場合は何もしない
     */
    private func startReconnectProcess() {
        guard reconnectTimer == nil else { return }
        reconnectAttempts = 0
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.attemptReconnect()
        }
    }
    
    /**
     * 再接続の試行
     * 
     * 最大試行回数まで再接続を試行する
     * 接続が復旧するか、最大試行回数に達するまで継続
     */
    private func attemptReconnect() {
        // 最大試行回数に達した場合の処理
        guard reconnectAttempts < maxReconnectAttempts else {
            print("MultipeerManager: Max reconnect attempts reached")
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            return
        }
        
        // 既に接続が復旧している場合
        if !session.connectedPeers.isEmpty {
            print("MultipeerManager: Connection already restored")
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            needsReconnect = false
            reconnectAttempts = 0
            return
        }
        
        // 再接続の実行
        reconnectAttempts += 1
        print("MultipeerManager: Attempting reconnect \(reconnectAttempts)/\(maxReconnectAttempts)")
        stop()
        setupSession()
        start()
    }
    
    /**
     * ユーザー名変更に伴うピアID更新
     * 
     * ユーザーが名前を変更した際に、新しい名前でピアIDを再作成し、
     * サービスを再起動する
     */
    func updatePeerIdWithUserName() {
        let userName = UserDefaults.standard.string(forKey: "localUserName") ?? UIDevice.current.name
        let deviceName = userName
            .replacingOccurrences(of: " ", with: "_")
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        let truncatedName = String(deviceName.prefix(10))
        
        // サービスを停止してピアIDを更新
        stop()
        self.myPeerId = MCPeerID(displayName: truncatedName)
        setupSession()
        start()
    }
}

// MARK: - MCSessionDelegate
/**
 * MCSessionDelegateの実装
 * MultipeerConnectivityセッションの状態変化とデータ受信を処理
 */
extension MultipeerConnectionManager: MCSessionDelegate {
    /**
     * ピアの接続状態変化時の処理
     * - Parameter session: MultipeerConnectivityセッション
     * - Parameter peerID: 状態が変化したピア
     * - Parameter state: 新しい接続状態
     */
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                print("MultipeerManager: Connected to peer: \(peerID.displayName)")
                // 接続ピアリストの更新
                self.connectedPeers = session.connectedPeers
                
                // 再接続関連の状態をクリア
                self.reconnectTimer?.invalidate()
                self.reconnectTimer = nil
                self.needsReconnect = false
                self.reconnectAttempts = 0
                
                // メッセージング管理に保留メッセージの送信を委譲
                self.messagingManager?.trySendingPendingMessages()
                
            case .connecting:
                print("MultipeerManager: Connecting to peer: \(peerID.displayName)")
                
            case .notConnected:
                print("MultipeerManager: Disconnected from peer: \(peerID.displayName)")
                // 接続ピアリストの更新
                self.connectedPeers = session.connectedPeers
                
                // 全ての接続が切れた場合のみ再接続を開始
                if self.connectedPeers.isEmpty && !self.needsReconnect {
                    self.needsReconnect = true
                    self.startReconnectProcess()
                }
                
            @unknown default:
                print("MultipeerManager: Unknown state for peer: \(peerID.displayName)")
            }
        }
    }
    
    /**
     * データ受信時の処理
     * - Parameter session: MultipeerConnectivityセッション
     * - Parameter data: 受信データ
     * - Parameter peerID: 送信者のピア
     * 
     * 受信したデータをメッセージングマネージャーに委譲して処理
     */
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // メッセージ受信をメッセージング管理に委譲
        messagingManager?.handleReceivedData(data, fromPeer: peerID, session: session)
    }
    
    // MARK: - Unused MCSession Delegate Methods
    /// ストリーム受信（未実装）
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    
    /// リソース受信開始（未実装）
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    
    /// リソース受信完了（未実装）
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate
/**
 * MCNearbyServiceBrowserDelegateの実装
 * 近隣ピアの発見と管理を処理
 */
extension MultipeerConnectionManager: MCNearbyServiceBrowserDelegate {
    /**
     * ピア発見時の処理
     * - Parameter browser: ブラウザインスタンス
     * - Parameter peerID: 発見されたピア
     * - Parameter info: 発見情報（今回は未使用）
     */
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        print("MultipeerManager: Found peer: \(peerID.displayName)")
        // 発見したピアに接続招待を送信（タイムアウト30秒）
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }
    
    /**
     * ピアロスト時の処理
     * - Parameter browser: ブラウザインスタンス
     * - Parameter peerID: 見失ったピア
     */
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("MultipeerManager: Lost peer: \(peerID.displayName)")
    }
    
    /**
     * ブラウザ開始失敗時の処理
     * - Parameter browser: ブラウザインスタンス
     * - Parameter error: 発生したエラー
     */
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("MultipeerManager: Failed to start browsing: \(error.localizedDescription)")
        printDetailedError(error)
    }
    
    /**
     * エラー詳細情報の出力
     * - Parameter error: 詳細を出力するエラー
     */
    private func printDetailedError(_ error: Error) {
        print("Error domain: \((error as NSError).domain)")
        print("Error code: \((error as NSError).code)")
        print("Error description: \(error.localizedDescription)")
        print("User info: \((error as NSError).userInfo)")
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate
/**
 * MCNearbyServiceAdvertiserDelegateの実装
 * 自身の広告と招待の受理を処理
 */
extension MultipeerConnectionManager: MCNearbyServiceAdvertiserDelegate {
    /**
     * 招待受信時の処理
     * - Parameter advertiser: アドバタイザインスタンス
     * - Parameter peerID: 招待元のピア
     * - Parameter context: 招待コンテキスト（今回は未使用）
     * - Parameter invitationHandler: 招待への応答ハンドラ
     */
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("MultipeerManager: Invitation from: \(peerID.displayName)")
        // 招待を自動受諾（trueで受諾、現在のセッションを使用）
        invitationHandler(true, session)
    }
    
    /**
     * アドバタイザ開始失敗時の処理
     * - Parameter advertiser: アドバタイザインスタンス
     * - Parameter error: 発生したエラー
     */
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("MultipeerManager: Failed to start advertising: \(error.localizedDescription)")
        printDetailedError(error)
    }
}
