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

**トランスクリプトをメインスレッドで読まない。** 実測でセッション 1 本あたり 1.6MB・全文パース 17ms。これをメインスレッドで 2 秒ごとに回していたためパネルのアニメーションが引っかかっていた。`SummaryStore` / `TranscriptStore` は専用の `DispatchQueue` で読み、結果だけ main に戻す。

**要約は差分だけ読む。** `TranscriptReader.scanSummary(from:resuming:)` が前回のバイトオフセットから追記分だけを読む（1 ティック 0.14ms）。追記途中の行は最後の改行までで切って次回に回し、ファイルが縮んでいたら（コンパクション）先頭から読み直す。`loadSummary` は全文版のままだが、ポーリング経路では使わない。

**`ISO8601DateFormatter` を毎回 new しない。** タイムスタンプ 1 行ごとの生成がプロファイル上の最大コストだった。値型で `Sendable` な `Date.ISO8601FormatStyle` を static で共有する。

**トークンは保持しない。** CLI がおよそ 1 時間ごとにローテートするため、`ClaudeCredentials.accessToken()` を毎回呼ぶ。

**コストは請求額ではない。** 定額プランはトークン単位で課金されないため、`TokenPricing` が出すのは「同じ処理を従量課金の API で回した場合」の換算値。UI と書き出しの両方でこの但し書きを外さない。単価表は `Models/TokenPricing.swift` の一箇所だけに置く。日付入りのスナップショット ID（`claude-sonnet-4-5-20250929`）や未知の新モデルは `families` のキーワード一致でティア単価に落ちるので、モデルが増えても金額が黙って 0 にならない。ティアが変わったときだけ表を直す。

**パターンルールは連結したコマンドを通さない。** `xcodegen generate *` を許可しても、`xcodegen generate && rm -rf /` は自動許可してはならない。`AlwaysAllowRule.matches` はシェル系ツール（`Bash` / `BashOutput`）に限り、`&&` `||` `;` `|` `` ` `` `$(` 改行 `>` `<` のいずれかを含む入力ではパターン照合を降りて通常の承認に戻す。前方一致だけで判定すると、承認済みの接頭辞の後ろに任意のコマンドを連結できてしまう。`chainingTokens` を削らない。

**繰り返しアニメーションを SwiftUI で書かない。** `repeatForever` を使うと、そのアニメーションが動いているあいだ `NSHostingView` のレイアウトが毎フレーム走る。常時見えているノッチでは実測で CPU が 5% → 55% になった。マークの回転（`ClaudeMark.swift` の `MarkLayerView`）と稼働中の点（`Motion.swift` の `PulseDotView`）は `CABasicAnimation` をレイヤに載せて逃がしている。さらに `shouldRasterize` で焼き付け、`preferredFrameRateRange` を 24fps に落として 5% 台に戻した。この 3 点（レイヤ・ラスタライズ・フレームレート）のどれを外しても数十 % 戻る。状態が変わった瞬間の一度きりのアニメーションは SwiftUI 側でよい。

**UI を全部隠せる状態を作らない。** メニューバーアイコンとノッチパネルは個別に非表示にできるが、両方消しても `applicationShouldHandleReopen` で設定ウィンドウに戻れる。承認待ちが発生したときは `showNotchPanel` が false でもパネルを前面に出す（`NotchWindowController` の `approvals.$pending` 監視）。ブロックされたセッションに応答できない状態を作らないため。

## Swift 6 concurrency の扱い

strict concurrency が有効なため、以下の型を踏襲する。

- バックグラウンドから値を受け取る `ObservableObject` は `@unchecked Sendable` にし、`DispatchQueue.main.async` で必ず main に跳ばしてから `@Published` を触る（`ApprovalStore` / `UsageStore` / `SummaryStore` / `TranscriptStore`）。どのプロパティをどのキューが所有するかはコメントで明示する（`SummaryStore.cache` は専用キュー、`summaries` は main）。
- `deinit` から非 Sendable なプロパティに触れない。アプリ生存期間中ずっと生きるオブジェクトの `NSEvent` モニタは解放しない方針にしている（`NotchWindowController.clickMonitor`）。
- `Timer.scheduledTimer` のクロージャは main 分離ではないので、`@MainActor` を付けたクラスからは使えない。既存のストアはあえて素のクラスにしている。

## 設定

`AppSettings`（`Services/AppSettings.swift`）が唯一の設定の置き場。`UserDefaults` に永続化し、`@Published` で配る。

- 各ストアは `AppSettings.shared` を既定引数で受け取り、間隔の `@Published` を購読して**タイマーを張り直す**（`restartTimer(interval:)`）。定数のポーリング間隔を新しく埋め込まない。
- 新しい設定を足すときは、`Key` に追加 → `init` の読み込み → `resetToDefaults()` の 3 箇所を揃える。どれか一つでも漏れるとリセットが効かない。
- 設定ウィンドウは `SettingsWindowController` が持つ AppKit の `NSWindow`。`Settings` シーンは空のまま（`App` にシーンが要るだけ）。アクセサリアプリはウィンドウを前面に出しただけでは活性化しないので、`present()` で `NSApp.activate` してから `makeKeyAndOrderFront` する。
- ペインの切り替えは `toolbarStyle = .preference` の `NSToolbar`。SwiftUI の `TabView` は `Settings` シーンの外だと囲み付きのインラインタブとして描かれるので使わない。ペインを増やすときは `SettingsPane` に case を足すだけでツールバーもショートカットも追随する。
- ウィンドウの高さはペインごとに `fittingSize` を測って合わせる（`SettingsPane.fallbackHeight` は測れなかったときの保険）。全ペイン共通の固定サイズにしない。

## 承認プロトコル

ソケットは `~/Library/Application Support/ClaudeNotch/approvals.sock`。改行区切り JSON で 1 往復する。

```
bridge → app   フックの stdin をそのまま + "\n"
app → bridge   {"behavior":"allow"} または {"behavior":"deny"} + "\n"
               無応答で閉じた場合はターミナルに委譲
```

ブリッジは応答を 120 秒待つ。フック側の `timeout` はこれより長くしておくこと（150 秒程度）。

承認待ちの間はパネルを閉じさせない（`NotchWindowController` のクリック監視が `approvals.pending` を見ている）。セッションがブロックされたまま UI が消えると復帰手段がなくなるため。

### フックが渡してくる中身

実測したペイロードの形。ドキュメントに載っていない項目があるので、変更するときは実データで確かめる。

```
session_id / transcript_path / cwd / prompt_id / permission_mode / effort
tool_name / tool_input / permission_suggestions
```

`tool_input` はツールごとに形が違う。`ApprovalRequest.interpret` がここを引き受け、パネルは `ApprovalBody` だけを見る。

| ツール | 使う項目 |
| --- | --- |
| Bash | `command` と `description`（`description` が見出しになる） |
| Edit | `file_path` / `old_string` / `new_string` → 差分表示 |
| Write | `file_path` / `content` |
| Read | `file_path` のみ（本文なし） |

`permission_suggestions` には CLI 自身が出す候補が入る。`addRules` の `ruleContent`（`xcodegen generate *` など）だけを拾い、`setMode` は捨てる。**フックが返せるのは `behavior` と `updatedInput` だけで、モード変更やルール追加は返せない**ため、`setMode` を UI に出しても実行できない。

### 返せないもの

- セッションのモード変更（`acceptEdits` など）。「そのツールを常に許可」で代替するしかない。
- 拒否理由を Claude に伝える経路は**未確認**。`additionalContext` / `reason` / `systemMessage` のどれが効くかは実機検証が要る。承認要求を出さない権限モードのセッションからは検証できない点に注意。

## 常に許可

`AlwaysAllowStore`（`UserDefaults` の `alwaysAllowRules`）が標準の承認を保持し、`ApprovalStore` がパネルを出す前に照合する。一致すれば通知もパネルも出さずに `allow` を返す。

粒度は 3 つ。UI では色で区別する。

| scope | 意味 | 由来 |
| --- | --- | --- |
| `pattern` | `xcodegen generate *` のような前方一致 | `permission_suggestions` の候補 |
| `exact` | 入力が完全一致したときだけ | 候補がないときのフォールバック |
| `tool` | そのツールの全呼び出し | 手動選択のみ。オレンジで警告する |

`~/.claude/settings.json` は書き換えない。アプリ内に閉じているので、一覧と削除がアプリだけで完結する。

**ルールは必ず一覧から消せるようにしておく。** 一覧はセッション一覧ヘッダーの盾バッジから開く（`AlwaysAllowRulesView`）。押した本人が後から気づけない標準承認は作らない。

## 構成

```
Sources/Bridge/            フックから起動される CLI。依存なしの POSIX ソケット
Sources/ClaudeNotch/
  Models/                  ClaudeSession, SessionDetail, ApprovalRequest, UsageSnapshot
  Services/                ファイル監視・パース・ソケットサーバ・端末特定・設定
  Views/                   SwiftUI。NotchContentView が折りたたみ/展開を切り替える
  Windows/                 NSPanel・設定ウィンドウ・メニューバー。AppKit 側の器
```

`NotchWindow` は `.nonactivatingPanel` かつ `canBecomeKey = false`。ターミナルからフォーカスを奪わないための設計なので、ここを変えるとタイピング中に入力を吸ってしまう。

ウィンドウのサイズは `NotchWindowController` が持ち、SwiftUI 側は `NotchUIState` の `isHovering` / `isPinned` を通じて開閉を要求する。

## 現在の状態

承認機能は `~/.claude/settings.json` の `PermissionRequest` にフック登録済みで、実機で往復を確認してある（手順は README）。設定ファイルを編集するときは必ずバックアップを取る。

このマシンには AgentPeek と codeisland のフックも同じイベントに載っている。同一イベントのフックは並行実行されるので、複数が決定を返したときの優先順位は未確認。

拒否理由の伝達だけ未検証のまま残っている。検証するときは、合言葉を含む入力のときだけ拒否を返す一時フックを足し、**承認プロンプトが実際に出るセッション**から叩く。権限モードによっては `PermissionRequest` 自体が発生せず、いくら実行しても再現しない。検証用フックは他セッションの入力も受け取るので、終わったら必ず外してログを消す。
