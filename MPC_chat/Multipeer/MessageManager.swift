import Foundation
import UIKit
import SQLite3

// MARK: - メッセージ永続化管理
/**
 * MultipeerMessageManager
 * 
 * SQLiteを使用したメッセージデータの永続化を専門的に管理するクラス
 * 責任範囲:
 * - SQLiteデータベースの作成と管理
 * - メッセージの保存（送信履歴、受信確認）
 * - メッセージの取得と検索
 * - デバッグ用のログ出力
 * 
 * シングルトンパターンで実装され、アプリ全体で単一のインスタンスを共有
 */
class MultipeerMessageManager {
    // MARK: - Singleton
    /// シングルトンインスタンス
    static let shared = MultipeerMessageManager()
    
    /// プライベート初期化（シングルトン実装）
    private init() {}
    
    // MARK: - Database Schema
    /**
     * SQLiteテーブル構造:
     * - messages_id: プライマリキー（自動増分）
     * - sender_id: 送信者ID（ユーザー名）
     * - receiver_id: 受信者ID（デバイスのUUID）
     * - message_text: メッセージ本文
     * - created_at: 作成日時（自動設定）
     * - synced_at: 同期日時（将来のサーバー同期用、現在はNULL）
     * - local_unique_id: ローカル固有ID（重複防止用）
     * - UNIQUE制約: (sender_id, local_unique_id) で重複防止
     */
    
    // MARK: - Public Methods
    /**
     * メッセージをローカルDBに保存する
     * - Parameter message: 保存するメッセージ内容
     * - Parameter receiverId: 受信者ID（通常はデバイスのUUID）
     * 
     * 処理フロー:
     * 1. 送信者IDを取得（UserDefaultsまたはデバイス名）
     * 2. SQLiteデータベースを開く
     * 3. テーブルが存在しない場合は作成
     * 4. メッセージを一意のIDと共に挿入
     * 5. 保存確認のため全メッセージをログ出力
     */
    func saveMessageLocally(_ message: String, receiverId: String) {
        // 送信者IDの取得
        let senderId = UserDefaults.standard.string(forKey: "localUserName") ?? UIDevice.current.name
        
        // データベースパスの構築
        let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/messages.sqlite3")
        var db: OpaquePointer? = nil
        
        // データベースオープン
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[DB] open error")
            return
        }
        defer { sqlite3_close(db) }

        // テーブル作成（存在しない場合のみ）
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

        // メッセージ挿入
        let insert = "INSERT OR IGNORE INTO messages (sender_id, receiver_id, message_text, local_unique_id) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer? = nil
        if sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK {
            let localUniqueId = UUID().uuidString
            
            // パラメータバインド
            sqlite3_bind_text(stmt, 1, (senderId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (receiverId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (message as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (localUniqueId as NSString).utf8String, -1, nil)
            
            if sqlite3_step(stmt) == SQLITE_DONE {
                print("[DB] message saved: sender=\(senderId), receiver=\(receiverId), text=\(message)")
                
                // 保存確認のため全メッセージを表示
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

    /**
     * DBに保存されたメッセージ一覧を取得する
     * - Returns: メッセージのタプル配列 (senderId, receiverId, messageText, createdAt, localUniqueId)
     * 
     * 処理フロー:
     * 1. データベースを開く
     * 2. テーブルが存在しない場合は作成
     * 3. 全メッセージを新しい順（messages_id DESC）で取得
     * 4. 結果を配列として返す
     */
    func fetchAllSavedMessages() -> [(senderId: String, receiverId: String, messageText: String, createdAt: String, localUniqueId: String)] {
        let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/messages.sqlite3")
        var db: OpaquePointer? = nil
        var result: [(String, String, String, String, String)] = []
        
        // データベースオープン
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[DB] open error (fetch)")
            return result
        }
        defer { sqlite3_close(db) }

        // テーブル作成（存在しない場合のみ）
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

        // メッセージ取得クエリ（新しい順）
        let query = "SELECT sender_id, receiver_id, message_text, created_at, local_unique_id FROM messages ORDER BY messages_id DESC;"
        var stmt: OpaquePointer? = nil
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            // 結果を一行ずつ処理
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

    /**
     * DBに保存されたメッセージをログ出力する（デバッグ用）
     * 
     * 開発・デバッグ時にデータベースの内容を確認するための便利メソッド
     * fetchAllSavedMessages()を使用して全メッセージを取得し、整形して出力
     */
    func printAllSavedMessagesToLog() {
        let messages = fetchAllSavedMessages()
        print("[DB] --- Saved messages ---")
        for msg in messages {
            print("[DB] sender: \(msg.senderId), receiver: \(msg.receiverId), text: \(msg.messageText), at: \(msg.createdAt), uuid: \(msg.localUniqueId)")
        }
        print("[DB] --- End ---")
    }
}
