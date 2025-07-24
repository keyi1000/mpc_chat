# MPC_chat

## 概要

MPC_chat は、iOS 向けのマルチピア通信（MultipeerConnectivity）と WebSocket を組み合わせたリアルタイムチャットアプリです。近くのデバイス同士で UUID 交換を行い、サーバー経由でメッセージ送信・受信が可能です。

## 主な機能

- MultipeerConnectivity によるデバイス間 UUID 交換
- WebSocket（wss://mpc_websocket.keyi9029.com/ws）によるサーバー通信
- 送信者・受信者 ID 付きメッセージ送信
- SQLite/NSUserDefaults による未送信メッセージの保存・再送
- 受信メッセージの UI 表示制御
- .env ファイルによる WebSocket サーバー URL 管理

## ファイル構成

- `MPC_chat/` : アプリ本体（SwiftUI）
  - `ContentView.swift` : メイン画面
  - `Websocket.swift` : WebSocket 通信管理
  - `MultipeerManager.swift` : MultipeerConnectivity 管理
  - `Assets.xcassets/` : アイコン・カラー等
- `MPC_chatTests/` : 単体テスト
- `MPC_chatUITests/` : UI テスト
- `.env` : WebSocket サーバー URL 設定
- `.gitignore` : 不要ファイル除外

## .env の使い方

WebSocket サーバーの URL は`.env`で管理します。
例:

```
WEBSOCKET_URL=自身のWSサーバ
```

## ビルド・実行方法

1. Xcode でプロジェクトを開く
2. 必要に応じて`.env`の URL を編集
3. iOS シミュレータまたは実機で実行

## 注意事項

- `.env`は`.gitignore`により Git 管理外です。必要に応じて各環境で作成してください。
- WebSocket サーバー URL を変更する場合は`.env`を編集してください。

## ライセンス

このプロジェクトは MIT ライセンスです。

---

ご質問・不具合は GitHub Issue または開発者までご連絡ください。
