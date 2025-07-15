import Foundation
import UIKit
import SQLite3

// MARK: - メッセージ送信・保存管理
class MultipeerMessageManager {
    static let shared = MultipeerMessageManager()
    private init() {}
    
    // メッセージをローカルDBに保存する関数
    func saveMessageLocally(_ message: String, receiverId: String) {
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

    // DBに保存されたメッセージをログ出力する（デバッグ用）
    func printAllSavedMessagesToLog() {
        let messages = fetchAllSavedMessages()
        print("[DB] --- Saved messages ---")
        for msg in messages {
            print("[DB] sender: \(msg.senderId), receiver: \(msg.receiverId), text: \(msg.messageText), at: \(msg.createdAt), uuid: \(msg.localUniqueId)")
        }
        print("[DB] --- End ---")
    }
}
