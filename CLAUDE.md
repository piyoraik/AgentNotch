# CLAUDE.md

AgentNotch は Claude Code のセッションをノッチとメニューバーから監視・操作する macOS アプリ。SwiftUI + AppKit、Swift 6 strict concurrency、macOS 14 以降、Apple Silicon。

## ビルド

```bash
# 新しい .swift ファイルを追加したときだけ必要
xcodegen generate

xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch \
  -configuration Debug -destination 'platform=macOS' build
```

ターゲットは 2 つ。GUI アプリの `AgentNotch` と、フックから起動される CLI の `agentnotch-bridge`。

既存ファイルの編集だけなら `xcodegen generate` は不要。`project.yml` がソースオブトゥルースで、`.xcodeproj` は生成物。**`.xcodeproj` を直接編集しない。**

**動きの善し悪しは Debug ビルドで判断しない。** 同じ状態（パネルを開いたまま）で実測して Debug 18.2% / Release 0.2% と 2 桁違う。SwiftUI は最適化なしだと 1 フレームあたりのコストが跳ね上がるので、「もっさりする」の切り分けは必ず Release で行う。

```bash
xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch \
  -configuration Release -destination 'platform=macOS' build
```

起動確認は次の流れで行う。

```bash
pkill -f "AgentNotch.app/Contents/MacOS/AgentNotch"
open "$(xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/AgentNotch.app"
```

`LSUIElement` アプリなので Dock に出ない。プロセスの生存確認は `ps aux | grep AgentNotch`。

## 名前とアイコン

アプリ名に Claude を入れない。監視対象は今のところ Claude Code だけだが、他のコーディングエージェントを足せる前提の名前にしてある。**「Claude Code のセッションを見る」という説明はそのまま使ってよいが、アプリ自身の識別子（バンドル ID・ソケットのディレクトリ・キュー名・ウィンドウのタイトル）に Claude を入れない。** 逆に、Claude Code のデータを指す型名（`ClaudeSession` / `ClaudeCredentials`）と `~/.claude` のパスは Claude のものなので変えない。

アイコンは自前で描いたもので、Claude のスパークマークは使わない。ソースは `Design/generate-icon.py` で、SVG と `Resources/Assets.xcassets/AppIcon.appiconset/*.png` の両方を書き出す。

```bash
python3 Design/generate-icon.py
```

**SVG を手で直さない。** スクリプトの上書き対象なので、形を変えるときは `Design/generate-icon.py` の定数を直して回す。円弧の座標を手計算しないための仕組み。

ラスタライズは Chrome のヘッドレスに任せている（librsvg も ImageMagick も入っていないため）。`--window-size` は切り取るだけで縮めないので、目的のサイズの `<img>` を挟んだ HTML を経由する。SVG を直接開くと常に 1024 で描かれる。

**マークの比率は 2 箇所にある。** `Design/generate-icon.py` の `R` / `W` / `PUPIL`（`OUTER` に対する比）と、`Sources/AgentNotch/Views/AgentMark.swift` の `AgentMark` の `ringRadius` / `ringWidth` / `pupilRadius`。片方だけ直すとアイコンと UI のマークが違う形になる。

**マークは塗りのパスで組む。** ストロークで描くと `MarkBitmap` が塗れず形が出ない。`AgentMark.path` は外周 → 終端の丸キャップ → 内周を逆向き → 始端の丸キャップの順に閉じ、nonzero でドーナツの穴を空けている。`addArc` の `clockwise: false` が角度の増える向き（画面上の時計回り）。ここを反転させると輪が塗り潰れる。

**寒色が通常、暖色が注意。** `AgentBrand` はミント〜アズールの寒色で、承認待ちと警告だけ `amber` を使う。ノッチのように小さく速く読む UI では、「動いている」と「人間の応答を待っている」を色温度だけで見分けられるのが効く。単色で足りるところは `AgentBrand.accent`（ミント）を使い、色を新しく増やさない。`ClaudeBrand`（クレイ系）は**Claude Code を指すマークだけ**の色で、アプリの色として使わない。

### どちらのマークを出すか

`MarkArt` の 2 つを「誰を指しているか」で使い分ける。**アプリの器か、監視対象か。**

| 出る場所 | マーク |
| --- | --- |
| メニューバーのアイコン | `agentRing`（`AgentMark.statusImage`） |
| 折りたたみのピル | `agentRing` |
| セッションが無いときのプレースホルダ | `agentRing` |
| 設定ウィンドウ | `agentRing` |
| パネル見出しの「Claude Code」ロックアップ | `claudeSpark` |
| セッション詳細の見出し・発言者 | `claudeSpark` |
| 使用状況レポートの見出し | `claudeSpark` |

`claudeSpark` は Claude.app が同梱している公式のトレイアイコン（`TrayIconTemplate@3x.png`）をそのまま `Resources/Assets.xcassets/ClaudeMark.imageset` に置いたもの。**自分で描き起こさない。** 以前は花弁を並べた `Shape` で近似していたが、形が違う上に出自が怪しかった。

アプリアイコンの `.icns` ではなくトレイ用を使うのは、`.icns` が角丸の下地込みのタイルで、12pt のグリフにすると塗り潰した四角になるため。**アセットは 72px の 1 枚だけ置く。** macOS は `@3x` を読まないので 24/48/72 の 3 枚を入れても 48px までしか出てこず、34pt（2x で 68px）が拡大になる。いちばん大きい 1 枚を 1x として持たせれば、どのサイズでも縮小方向にしかならない。

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

**ウィンドウの大きさが変わるところにアニメーションを足さない。** ノッチの開閉（`NotchWindowController.setExpanded`）と設定ウィンドウのペイン切り替え（`SettingsWindowController.show`）の両方。枠は AppKit、中身は SwiftUI と別々のアニメータになるため、曲線と長さを揃えても終わりが一致せずガタついて見える。どちらも `window.setFrame` で即座に切り替える。パネルを開いた直後に見えるもの（セッション一覧の行・使用量カード）も `staggeredAppear` を付けない。`Motion.navigate` などパネル内の画面遷移は別物なので残してよい。

**`@Published` の購読から同期で `setFrame(display: true)` しない。** `@Published` は willSet で値を流すため、購読側が同期で走った時点ではプロパティはまだ古い。そこで描画を強制すると、新しい枠に古い側のビューが描かれ、しかも直前に配信済みの `objectWillChange` がその描画で消費されて再描画が来ず、**枠と中身がずれたまま固まる**（展開サイズの窓に折りたたみの中身、あるいはその逆）。`NotchWindowController.observeState` の開閉チェーンは `.receive(on: DispatchQueue.main)` で 1 ターン遅らせて値を確定させてから枠を変える。これを外さない。アニメーションしていた頃は `animator()` がフレーム変更を預かっていたので表面化しなかった。

**ブリッジは必ずフェイルオープン。** `Sources/Bridge/main.swift` のすべての失敗経路は「終了コード 0・stdout 空」で抜ける。これは Claude Code に「判断しない」と解釈され、通常のターミナル承認にフォールバックする。ここでエラーを出したりハングしたりすると、**マシン上の全セッションが停止する**。この性質を壊す変更をしない。

**`NSScreen.main` を使わない。** アクセサリアプリはキーウィンドウを持たないため、`NSScreen.main` が外部ディスプレイを指す。ノッチの検出は `ScreenLocator` が `safeAreaInsets.top` と `auxiliaryTopLeftArea` で行う。

**表示先の指定は UUID で持つ。** `AppSettings.preferredScreenID` は `CGDisplayCreateUUIDFromDisplayID` の文字列。`CGDirectDisplayID` はセッションごとに振り直されるので永続化に使わない。空文字列が「自動（ノッチのある画面）」。**指定したディスプレイが外れていても設定は消さない。** 外れている間は自動選択に落ち、挿し直せば元の画面に戻る。ここでクリアすると、ケーブルを抜いた一度きりの操作でユーザーの選択が失われる。ノッチのない画面を選んだときは `hasNotch: false` でメニューバーの下に同じ形のピルを描く（高さは `frame.maxY - visibleFrame.maxY`、取れなければ 24pt）。

**画面が変わったら中身も作り直す。** ノッチの幅と高さは `NotchContentView` に初期化時の値として渡るので、`NotchWindowController.relocate` が枠を張り直したあと、この 3 つ（`hasNotch` / `notchWidth` / `notchHeight`）のどれかが動いたときだけ `installContentView` する。毎回作り直すと開いている子画面が飛び、一度も作り直さないとノッチのない画面でノッチ幅の切り欠きが残る。ディスプレイの抜き差しは `NSApplication.didChangeScreenParametersNotification` で拾う。

**ファイル読み込みは mtime でガードする。** `SummaryStore` と `TranscriptStore` は更新日時が変わったときだけ再パースする。毎秒の再読み込みはしない。

**トランスクリプトをメインスレッドで読まない。** 実測でセッション 1 本あたり 1.6MB・全文パース 17ms。これをメインスレッドで 2 秒ごとに回していたためパネルのアニメーションが引っかかっていた。`SummaryStore` / `TranscriptStore` は専用の `DispatchQueue` で読み、結果だけ main に戻す。

**要約は差分だけ読む。** `TranscriptReader.scanSummary(from:resuming:)` が前回のバイトオフセットから追記分だけを読む（1 ティック 0.14ms）。追記途中の行は最後の改行までで切って次回に回し、ファイルが縮んでいたら（コンパクション）先頭から読み直す。`loadSummary` は全文版のままだが、ポーリング経路では使わない。

**`ISO8601DateFormatter` を毎回 new しない。** タイムスタンプ 1 行ごとの生成がプロファイル上の最大コストだった。値型で `Sendable` な `Date.ISO8601FormatStyle` を static で共有する。

**トークンは保持しない。** CLI がおよそ 1 時間ごとにローテートするため、`ClaudeCredentials.accessToken()` を毎回呼ぶ。

**コストは請求額ではない。** 定額プランはトークン単位で課金されないため、`TokenPricing` が出すのは「同じ処理を従量課金の API で回した場合」の換算値。金額を出す画面からこの但し書きを外さない。単価表は `Models/TokenPricing.swift` の一箇所だけに置く。日付入りのスナップショット ID（`claude-sonnet-4-5-20250929`）や未知の新モデルは `families` のキーワード一致でティア単価に落ちるので、モデルが増えても金額が黙って 0 にならない。ティアが変わったときだけ表を直す。

**合計は画面に出ている行から作る。** `SummaryStore.refresh` はスキャン実行中の要求を落とすので、`summaries` はセッション終了後も次のスキャンが終わるまで死んだセッションを抱えている。合計やシェアを `summaries.values` から取ると、その 1 周期だけ合計が行の和より大きく、シェアが 100% に届かない。`UsageReportView.aggregate` のように `sessions` から作った行を 1 回舐めて、合計・モデル別・分母をまとめて出す。行ごとに全体の合計を引き直さない。

**使用量メーターはパネル上端の一枚だけ。** `NotchContentView.expandedView` がサブ画面に関係なく常に `UsageStripView` を描く。詳細・レポートなどの子ビュー側で描くと二重になる。

**非表示設定で前面に出したら、畳むときに戻す。** 承認待ち（`approvals.$pending`）とメニューの「使用状況レポート…」（`NotchWindowController.showReport`）は `showNotchPanel` が false でも窓を出す。戻すのは `setExpanded(false)` の一箇所だけなので、そこに片付けを集約する。出しっぱなしにすると、折りたたんだピルが設定をトグルするまで画面に残る。

**パターンルールは連結したコマンドを通さない。** `xcodegen generate *` を許可しても、`xcodegen generate && rm -rf /` は自動許可してはならない。`AlwaysAllowRule.matches` はシェル系ツール（`Bash` / `BashOutput`）に限り、`&&` `||` `;` `|` `` ` `` `$(` 改行 `>` `<` のいずれかを含む入力ではパターン照合を降りて通常の承認に戻す。前方一致だけで判定すると、承認済みの接頭辞の後ろに任意のコマンドを連結できてしまう。`chainingTokens` を削らない。

**繰り返しアニメーションを SwiftUI で書かない。** `repeatForever` を使うと、そのアニメーションが動いているあいだ `NSHostingView` のレイアウトが毎フレーム走る。常時見えているノッチでは実測で CPU が 5% → 55% になった。マークの回転（`MarkLayer.swift` の `MarkLayerView`）と稼働中の点（`Motion.swift` の `PulseDotView`）は `CABasicAnimation` をレイヤに載せて逃がしている。`preferredFrameRateRange` は 24fps に落とす。常に出ているノッチでゆっくりした回転に 120fps 相当を回す価値はない。状態が変わった瞬間の一度きりのアニメーションは SwiftUI 側でよい。

**回すのは 1 枚の焼いた絵にする。マスクを回さない。** マークは `MarkBitmap.bake` が「グラデーション + 形」を実ピクセル数ぴったりのビットマップに潰し、`MarkLayerView` はそれを `CALayer.contents` に置いて回すだけにしている。以前は `CAGradientLayer` を形でマスクして `shouldRasterize` で焼いていたが、**マスクはラスタライズのキャッシュに入らない**ので合成のたびに効く。12pt のマークを常時回した実測（Release・折りたたみ）で、形のマスクが 5.2%、公式アセットのアルファをマスクにしたものが 9.2%、焼いて 1 枚にしたものが 0.4%。`PulseDotView` のように塗りが動かないものは `shouldRasterize` のままでよい。

**焼き直しは条件が変わったときだけ。** `MarkLayerView.layout()` は SwiftUI 側の再評価に引きずられて**毎フレーム走る**。大きさ・倍率・状態を `built` に覚えて番をしないと、焼き付けのほうがマスクより高くつく（実測 9.8% → 18.3%）。

**`AgentMark` の向きに気をつける。** `Shape` なので y が下向きの前提で組んであり、開口部は真上。AppKit の y 上向きの文脈（`NSBitmapImageRep` のコンテキスト、`NSImage(size:flipped:)`）にそのまま流すと**上下が返って開口部が下にくる**。`MarkBitmap.ringPath` の反転と `AgentMark.statusImage` の `flipped: true` を外さない。輪に切れ目があるだけの形なので、逆でも破綻して見えず、アプリアイコンと上下が違うことに気づきにくい。

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
- ペインの並びは macOS の慣習どおり「一般が先頭・技術寄りが末尾」。`SettingsPane` の case 順がそのままタブ順と `⌘1`〜`⌘5` になる。`lastSettingsPane` は raw 文字列なので、case をリネームしても古い値は先頭ペインに落ちるだけで壊れない。
- ペインの切り替えは `toolbarStyle = .preference` の `NSToolbar`。SwiftUI の `TabView` は `Settings` シーンの外だと囲み付きのインラインタブとして描かれるので使わない。ペインを増やすときは `SettingsPane` に case を足すだけでツールバーもショートカットも追随する。
- ウィンドウの高さはペインごとに `fittingSize` を測って合わせる（`SettingsPane.fallbackHeight` は測れなかったときの保険）。全ペイン共通の固定サイズにしない。
- **タブの当たり判定はビューで持つ。** 画像とラベルだけ渡した `NSToolbarItem` は、56pt のセルに絵とラベルを描くのにクリックを受けるのはアイコンの 24×24 だけで（`isBordered` を立てても 30×24）、ラベルの上やアイコンの数 pt 横は無反応になる。実測でクリック座標を採ると、空振りは全部この余白に当たっていた。押しても切り替わらないので「タブは 2 回押さないと遷移しない」と見える。`PaneTabView`（`NSButton`）を `item.view` に入れてセル全体を押せるようにしてある。
- **タブの中身（アイコン・ラベル・選択のピル）は全部 `PaneTabView` が描く。** AppKit と分担すると必ずずれる。
  - アイコンとラベルは `layout()` で手で積む。`NSButton` の `imagePosition = .imageAbove` はセルが望みより低いと画像とタイトルを**重ねて**しまい、歯車が「一般」に、矢印が「データ更新」に食い込んだ。間隔は 3pt 以上空ける。
  - `displayMode` は `.iconOnly`。`.iconAndLabel` だとツールバーが 14pt のラベル欄を確保し、項目のビューがその上（高さ 35pt）に押し込められてアイコンが上にずれる。ラベルを `item.label` にも入れると、その欄に二枚目のラベルが描かれる。
  - `selectedItemIdentifier` は立てない。立てるとツールバーが選択のピルを**セル基準**（セル内 `y 8..56`）に描くが、項目のビューは `y 10..57` に引き伸ばされて置かれるため、アイコンとラベルの塊とピルの中心が 1.5pt ずれる。ピルは自分の bounds を上下対称に詰めて描き、内容と同心にする。
  - 高さの要求は通らない（セルの空きに合わせて 47pt になる）。それでも要求しないと内容ぴったりの 32pt しか渡らないので、上下の余白まで押せるようにセルより大きい値を返しておく。

## 承認プロトコル

ソケットは `~/Library/Application Support/AgentNotch/approvals.sock`。改行区切り JSON で 1 往復する。

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
Sources/AgentNotch/
  Models/                  ClaudeSession, SessionDetail, ApprovalRequest, UsageSnapshot
  Services/                ファイル監視・パース・ソケットサーバ・端末特定・設定
  Views/                   SwiftUI。NotchContentView が折りたたみ/展開を切り替える
  Windows/                 NSPanel・設定ウィンドウ・メニューバー。AppKit 側の器
Design/                    アイコンの生成スクリプトと生成された SVG
Resources/
  Assets.xcassets/         AppIcon（生成物）と ClaudeMark（Claude.app の公式アセット）
  Info.plist               project.yml からの生成物。.gitignore 済み
```

`NotchWindow` は `.nonactivatingPanel` かつ `canBecomeKey = false`。ターミナルからフォーカスを奪わないための設計なので、ここを変えるとタイピング中に入力を吸ってしまう。

ウィンドウのサイズは `NotchWindowController` が持ち、SwiftUI 側は `NotchUIState` の `isHovering` / `isPinned` を通じて開閉を要求する。

## 現在の状態

承認機能は `~/.claude/settings.json` の `PermissionRequest` にフック登録済みで、実機で往復を確認してある（手順は README）。設定ファイルを編集するときは必ずバックアップを取る。

このマシンには AgentPeek と codeisland のフックも同じイベントに載っている。同一イベントのフックは並行実行されるので、複数が決定を返したときの優先順位は未確認。

拒否理由の伝達だけ未検証のまま残っている。検証するときは、合言葉を含む入力のときだけ拒否を返す一時フックを足し、**承認プロンプトが実際に出るセッション**から叩く。権限モードによっては `PermissionRequest` 自体が発生せず、いくら実行しても再現しない。検証用フックは他セッションの入力も受け取るので、終わったら必ず外してログを消す。
