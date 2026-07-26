# CLAUDE.md

ClaudeNotch は Claude Code のセッションをノッチとメニューバーから監視・操作する macOS アプリ。SwiftUI + AppKit、Swift 6 strict concurrency、macOS 14 以降、Apple Silicon。

## ビルド

```bash
# 新しい .swift ファイルを追加したときだけ必要
xcodegen generate

xcodebuild -project ClaudeNotch.xcodeproj -scheme ClaudeNotch \
  -configuration Debug -destination 'platform=macOS' build
```

ターゲットは 2 つ。GUI アプリの `ClaudeNotch` と、フックから起動される CLI の `claudenotch-bridge`。

既存ファイルの編集だけなら `xcodegen generate` は不要。`project.yml` がソースオブトゥルースで、`.xcodeproj` は生成物。**`.xcodeproj` を直接編集しない。**

起動確認は次の流れで行う。

```bash
pkill -f "ClaudeNotch.app/Contents/MacOS/ClaudeNotch"
open "$(xcodebuild -project ClaudeNotch.xcodeproj -scheme ClaudeNotch \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/ClaudeNotch.app"
```

`LSUIElement` アプリなので Dock に出ない。プロセスの生存確認は `ps aux | grep ClaudeNotch`。

## データソース

すべて Claude Code がローカルに書くファイルを読むだけで、CLI との IPC は持たない（承認フックを除く）。

| パス | 内容 |
| --- | --- |
| `~/.claude/sessions/<pid>.json` | 実行中セッションの pid / sessionId / cwd / status。既定で 1 秒ごとにポーリング（間隔は設定で可変） |
| `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` | トランスクリプト。`usage` にトークン数、`ai-title` にタイトル |
| Keychain `Claude Code-credentials` | 使用量 API 用の OAuth トークン |

`<encoded-cwd>` は cwd の `/` と `.` を `-` に置換したもの（`/Users/x/.config` → `-Users-x--config`）。この規則は契約ではないため、`TranscriptReader.transcriptURL` は算出パスが外れたら全ディレクトリを走査する。

セッションファイルはプロセス終了後も残ることがあるので、`kill(pid, 0)` で生存を確認してから一覧に載せる。

## 守るべき不変条件

**ブリッジは必ずフェイルオープン。** `Sources/Bridge/main.swift` のすべての失敗経路は「終了コード 0・stdout 空」で抜ける。これは Claude Code に「判断しない」と解釈され、通常のターミナル承認にフォールバックする。ここでエラーを出したりハングしたりすると、**マシン上の全セッションが停止する**。この性質を壊す変更をしない。

**`NSScreen.main` を使わない。** アクセサリアプリはキーウィンドウを持たないため、`NSScreen.main` が外部ディスプレイを指す。ノッチの検出は `ScreenLocator` が `safeAreaInsets.top` と `auxiliaryTopLeftArea` で行う。

**ファイル読み込みは mtime でガードする。** `SummaryStore` と `TranscriptStore` は更新日時が変わったときだけ再パースする。毎秒の再読み込みはしない。

**トークンは保持しない。** CLI がおよそ 1 時間ごとにローテートするため、`ClaudeCredentials.accessToken()` を毎回呼ぶ。

**UI を全部隠せる状態を作らない。** メニューバーアイコンとノッチパネルは個別に非表示にできるが、両方消しても `applicationShouldHandleReopen` で設定ウィンドウに戻れる。承認待ちが発生したときは `showNotchPanel` が false でもパネルを前面に出す（`NotchWindowController` の `approvals.$pending` 監視）。ブロックされたセッションに応答できない状態を作らないため。

## Swift 6 concurrency の扱い

strict concurrency が有効なため、以下の型を踏襲する。

- バックグラウンドから値を受け取る `ObservableObject` は `@unchecked Sendable` にし、`DispatchQueue.main.async` で必ず main に跳ばしてから `@Published` を触る（`ApprovalStore` / `UsageStore`）。
- `deinit` から非 Sendable なプロパティに触れない。アプリ生存期間中ずっと生きるオブジェクトの `NSEvent` モニタは解放しない方針にしている（`NotchWindowController.clickMonitor`）。
- `Timer.scheduledTimer` のクロージャは main 分離ではないので、`@MainActor` を付けたクラスからは使えない。既存のストアはあえて素のクラスにしている。

## 承認プロトコル

ソケットは `~/Library/Application Support/ClaudeNotch/approvals.sock`。改行区切り JSON で 1 往復する。

```
bridge → app   フックの stdin をそのまま + "\n"
app → bridge   {"behavior":"allow"} または {"behavior":"deny"} + "\n"
               無応答で閉じた場合はターミナルに委譲
```

ブリッジは応答を 120 秒待つ。フック側の `timeout` はこれより長くしておくこと（150 秒程度）。

承認待ちの間はパネルを閉じさせない（`NotchWindowController` のクリック監視が `approvals.pending` を見ている）。セッションがブロックされたまま UI が消えると復帰手段がなくなるため。

## 構成

```
Sources/Bridge/            フックから起動される CLI。依存なしの POSIX ソケット
Sources/ClaudeNotch/
  Models/                  ClaudeSession, SessionDetail, ApprovalRequest, UsageSnapshot
  Services/                ファイル監視・パース・ソケットサーバ・端末特定
  Views/                   SwiftUI。NotchContentView が折りたたみ/展開を切り替える
  Windows/                 NSPanel とメニューバー。AppKit 側の器
```

`NotchWindow` は `.nonactivatingPanel` かつ `canBecomeKey = false`。ターミナルからフォーカスを奪わないための設計なので、ここを変えるとタイピング中に入力を吸ってしまう。

ウィンドウのサイズは `NotchWindowController` が持ち、SwiftUI 側は `NotchUIState` の `isHovering` / `isPinned` を通じて開閉を要求する。

## 現在の状態

承認機能は実装とエンドツーエンドの疎通確認まで済んでいるが、**`~/.claude/settings.json` へのフック登録は未実施**。登録手順は README を参照。設定ファイルを編集する際は必ずバックアップを取る。
