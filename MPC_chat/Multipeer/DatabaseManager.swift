import Foundation
import UIKit
import SQLite3

// MARK: - メッセージデータベース管理
/**
 * MultipeerDatabaseManager
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
class MultipeerDatabaseManager {
    // MARK: - Singleton
    /// シングルトンインスタンス
    static let shared = MultipeerDatabaseManager()
    
    /// プライベート初期化（シングルトン実装）
    private init() {}
    
    // MARK: - Database Schema
    /**
     * SQLiteテーブル構造:
     * - messages_id: プライマリキー（自動増分）
     * - sender_id: 送信者UUID（自分のデバイスUUID）
     * - receiver_id: 受信者UUID（相手のデバイスUUID）
     * - message_text: メッセージ本文
     * - created_at: 作成日時（自動設定）
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
    /**
     * メッセージをローカルDBに保存する
     * - Parameter message: 保存するメッセージ内容
     * - Parameter receiverId: 受信者のUUID
     * - Parameter senderId: 送信者のUUID（オプション、未指定時は自動取得）
     * 
     * 処理フロー:
     * 1. 送信者UUIDを取得または生成
     * 2. SQLiteデータベースを開く
     * 3. テーブルが存在しない場合は作成
     * 4. メッセージをUUIDと共に挿入
     * 5. 保存確認のため全メッセージをログ出力
     */
    func saveMessageLocally(_ message: String, receiverId: String, senderId: String? = nil) {
        // 送信者UUIDの取得
        let actualSenderId: String
        if let providedSenderId = senderId, !providedSenderId.isEmpty {
            actualSenderId = providedSenderId
        } else {
            // デバイス固有のUUIDを取得
            if let deviceUUID = UIDevice.current.identifierForVendor?.uuidString {
                actualSenderId = deviceUUID
            } else {
                actualSenderId = UUID().uuidString
                print("[DB] デバイスUUIDが取得できないため新しいUUIDを生成: \(actualSenderId)")
            }
        }
        
        print("[DB] 保存するメッセージ - sender_uuid: \(actualSenderId), receiver_uuid: \(receiverId), text: \(message)")
        
        // データベースパスの構築
        let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/messages.sqlite3")
        print("[DB] Database path: \(dbPath)")
        var db: OpaquePointer? = nil
        
        // データベースオープン
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[DB] open error: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_close(db) }

        // 既存のテーブル構造を確認
        let checkTable = "PRAGMA table_info(messages);"
        var stmt: OpaquePointer? = nil
        if sqlite3_prepare_v2(db, checkTable, -1, &stmt, nil) == SQLITE_OK {
            print("[DB] 既存のテーブル構造:")
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cid = sqlite3_column_int(stmt, 0)
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let type = String(cString: sqlite3_column_text(stmt, 2))
                let notnull = sqlite3_column_int(stmt, 3)
                let defaultValue = sqlite3_column_text(stmt, 4)
                let pk = sqlite3_column_int(stmt, 5)
                
                let defaultStr = defaultValue != nil ? String(cString: defaultValue!) : "NULL"
                print("[DB] カラム \(cid): \(name) \(type) NOT NULL=\(notnull) DEFAULT=\(defaultStr) PK=\(pk)")
            }
            sqlite3_finalize(stmt)
        }

        // テーブル作成（存在しない場合のみ）- シンプルなスキーマ
        let createTable = """
        CREATE TABLE IF NOT EXISTS messages (
          messages_id INTEGER PRIMARY KEY AUTOINCREMENT,
          sender_id TEXT NOT NULL,
          receiver_id TEXT NOT NULL,
          message_text TEXT NOT NULL,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """
        if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
            print("[DB] create table error: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        // メッセージ挿入
        let insert = "INSERT INTO messages (sender_id, receiver_id, message_text) VALUES (?, ?, ?);"
        stmt = nil  // 既存のstmt変数を再利用
        if sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK {
            // パラメータバインド
            sqlite3_bind_text(stmt, 1, (actualSenderId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (receiverId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (message as NSString).utf8String, -1, nil)
            
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_DONE {
                print("[DB] message saved: sender_uuid=\(actualSenderId), receiver_uuid=\(receiverId), text=\(message)")
                
                // 保存確認のため全メッセージを表示
                let all = fetchAllSavedMessages()
                print("[DB][確認] 現在DBに保存されている内容:")
                for s in all {
                    print("[DB][確認] sender_uuid=\(s.senderId), receiver_uuid=\(s.receiverId), message_text=\(s.messageText), created_at=\(s.createdAt)")
                }
            } else {
                print("[DB] insert error: step result=\(stepResult), error=\(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(stmt)
        } else {
            print("[DB] prepare error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /**
     * DBに保存されたメッセージ一覧を取得する
     * - Returns: メッセージのタプル配列 (senderId, receiverId, messageText, createdAt)
     * 
     * 処理フロー:
     * 1. データベースを開く
     * 2. テーブルが存在しない場合は作成
     * 3. 全メッセージを新しい順（messages_id DESC）で取得
     * 4. 結果を配列として返す
     */
    func fetchAllSavedMessages() -> [(senderId: String, receiverId: String, messageText: String, createdAt: String)] {
        let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/messages.sqlite3")
        var db: OpaquePointer? = nil
        var result: [(String, String, String, String)] = []
        
        // データベースオープン
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[DB] open error (fetch)")
            return result
        }
        defer { sqlite3_close(db) }

        // テーブル作成（存在しない場合のみ）- シンプルなスキーマ
        let createTable = """
        CREATE TABLE IF NOT EXISTS messages (
          messages_id INTEGER PRIMARY KEY AUTOINCREMENT,
          sender_id TEXT NOT NULL,
          receiver_id TEXT NOT NULL,
          message_text TEXT NOT NULL,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """
        if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
            print("[DB] create table error (fetch): \(String(cString: sqlite3_errmsg(db)))")
            return result
        }

        // メッセージ取得クエリ（新しい順）
        let query = "SELECT sender_id, receiver_id, message_text, created_at FROM messages ORDER BY messages_id DESC;"
        var stmt: OpaquePointer? = nil
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            // 結果を一行ずつ処理
            while sqlite3_step(stmt) == SQLITE_ROW {
                let senderId = String(cString: sqlite3_column_text(stmt, 0))
                let receiverId = String(cString: sqlite3_column_text(stmt, 1))
                let messageText = String(cString: sqlite3_column_text(stmt, 2))
                let createdAt = String(cString: sqlite3_column_text(stmt, 3))
                result.append((senderId, receiverId, messageText, createdAt))
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
            print("[DB] sender: \(msg.senderId), receiver: \(msg.receiverId), text: \(msg.messageText), at: \(msg.createdAt)")
        }
        print("[DB] --- End ---")
    }
    
    /**
     * データベース内のすべてのメッセージを削除する
     */
    func clearAllMessages() {
        let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/messages.sqlite3")
        var db: OpaquePointer? = nil

        // データベースを開く
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[DB] データベースを開けませんでした")
            return
        }
        defer { sqlite3_close(db) }

        // メッセージ削除クエリ
        let deleteQuery = "DELETE FROM messages;"
        if sqlite3_exec(db, deleteQuery, nil, nil, nil) == SQLITE_OK {
            print("[DB] すべてのメッセージを削除しました")
        } else {
            print("[DB] メッセージ削除エラー: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    
    /**
     * データベース接続テスト機能
     * アプリ起動時にデータベースが正常に動作するかテストする
     */
    func testDatabaseConnection() {
        print("[DB] データベース接続テストを開始します")
        
        // テストメッセージを保存
        let testMessage = "データベーステストメッセージ_\(Date().timeIntervalSince1970)"
        let testReceiver = "test_receiver_uuid"
        let testSender = "test_sender_uuid"
        
        saveMessageLocally(testMessage, receiverId: testReceiver, senderId: testSender)
        
        // 保存されたメッセージを取得
        let messages = fetchAllSavedMessages()
        let testFound = messages.contains { $0.messageText == testMessage && $0.receiverId == testReceiver && $0.senderId == testSender }
        
        if testFound {
            print("[DB] データベース接続テスト成功！")
        } else {
            print("[DB] データベース接続テスト失敗 - メッセージが見つかりません")
        }
        
        print("[DB] データベース接続テストを完了しました")
    }
    
    /**
     * データベースをリセットして新しい構造で再作成する
     */
    func resetDatabase() {
        let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/messages.sqlite3")
        var db: OpaquePointer? = nil

        // データベースを開く
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[DB] データベースリセット: 開けませんでした")
            return
        }
        defer { sqlite3_close(db) }

        // 既存テーブルを削除
        let dropTable = "DROP TABLE IF EXISTS messages;"
        if sqlite3_exec(db, dropTable, nil, nil, nil) == SQLITE_OK {
            print("[DB] 既存テーブルを削除しました")
        } else {
            print("[DB] テーブル削除エラー: \(String(cString: sqlite3_errmsg(db)))")
        }

        // 新しいテーブルを作成
        let createTable = """
        CREATE TABLE messages (
          messages_id INTEGER PRIMARY KEY AUTOINCREMENT,
          sender_id TEXT NOT NULL,
          receiver_id TEXT NOT NULL,
          message_text TEXT NOT NULL,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """
        if sqlite3_exec(db, createTable, nil, nil, nil) == SQLITE_OK {
            print("[DB] 新しいテーブルを作成しました")
        } else {
            print("[DB] 新テーブル作成エラー: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
}
