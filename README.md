<img src="Design/AgentNotchMark.svg" width="72" align="right" alt="">

# AgentNotch

Mac のノッチとメニューバーから Claude Code のセッションを監視し、承認に応答するためのネイティブ macOS アプリ。

ターミナルで普段どおり `claude` を起動するだけで、実行中のセッション・トークン消費・レート制限の残量がノッチに表示され、ツールの承認要求をノッチから直接さばける。

名前に Claude を含めていないのは、他のコーディングエージェントにも広げられるようにしてあるため。現時点で読んでいるのは Claude Code のファイルだけ。

## 必要環境

- macOS 14 以降、Apple Silicon
- ソースからビルドする場合は Xcode 26 以降と [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

ノッチのある内蔵ディスプレイがなくても動作する。その場合はメニューバー中央に同等のピルを表示する。

複数のディスプレイをつないでいるときは、設定の「表示」で表示先を選べる。既定ではノッチのある画面を自動で選ぶ。選んだディスプレイを外している間は自動選択に戻り、つなぎ直すと元の画面に戻る。

## インストール

[リリース](https://github.com/piyoraik/AgentNotch/releases/latest)の `AgentNotch-<version>.zip` を展開し、`AgentNotch.app` を `/Applications` に置く。

**Apple の署名を受けていないため、そのままでは開けない。** 配布に必要な Developer ID を持っていないので、公証を通していない。ダウンロードした .app には macOS が quarantine 属性を付けるので、これを外す。

```bash
xattr -dr com.apple.quarantine /Applications/AgentNotch.app
```

外さずに開くと「開発元を検証できないため開けません」と言われる。macOS 15 以降は Control クリックの抜け道が塞がれているので、その場合は**システム設定 → プライバシーとセキュリティ**を開いていちばん下の「このまま開く」を押す。

AgentNotch は Dock アイコンを出さない（`LSUIElement`）。**起動したかどうかはメニューバーのアイコンとノッチで判断する。** 何も出てこない場合は quarantine が外れていない可能性が高い。

自分でビルドしたものにはこの制約はかからない。手順は「[ビルド](#ビルド)」を参照。

## 機能

### セッション監視

`~/.claude/sessions/*.json` を 1 秒ごと（設定で変更可）に読み、プロセスが生存しているセッションだけを一覧表示する。

一覧の各行に、クリックせずとも以下が並ぶ。

- プロジェクト名と実行状態（busy / idle）
- Claude が付けたセッションタイトル（無ければ直近のプロンプト）
- コンテキスト量・累計出力トークン・モデル名
- 最終アクティビティからの経過時間

行をクリックすると詳細に入り、トークン内訳（Context / Output / Cache read / Cache write）と直近 60 件のトランスクリプトを読める。

### 使用量メーター

`claude` CLI と同じ OAuth エンドポイントを 1 分ごと（設定で変更可・オフにもできる）に参照し、5 時間ウィンドウと週間ウィンドウの消費率とリセットまでの残り時間をノッチに常時表示する。

### 承認

`PermissionRequest` フックを登録しておくと、ツールの承認要求がノッチにポップアップし、**許可 / 拒否 / ターミナルで決める** を選べる。ターミナルを見ていなくても、承認待ちで止まっているセッションに気付ける。

何を承認するのかはツールに応じて出し分ける。Bash はコマンドと Claude 自身が付けた説明、Edit は変更前後の差分、Write は書き込む内容が並ぶので、パネルだけ見て判断できる。

### 常に許可

同じ承認を繰り返さないよう、標準の承認を登録できる。

| 種別 | 範囲 |
| --- | --- |
| パターン | `xcodegen generate *` のような前方一致。Claude Code 自身が提案した範囲をそのまま使う |
| 完全一致 | 入力がまったく同じときだけ |
| ツール全体 | そのツールの呼び出しをすべて通す（強い。警告色で表示される） |

パターンで許可しても、`xcodegen generate && rm -rf /` のように**別のコマンドが連結されている場合は自動許可しない**。`&&` `;` `|` `` ` `` `$(` 改行 リダイレクトのいずれかを含むコマンドは、通常どおり承認を求める。

登録したルールはセッション一覧の盾バッジから一覧・削除できる。`~/.claude/settings.json` は書き換えないので、消せばアプリ側だけで元に戻る。

### ターミナルへのジャンプ

一覧・詳細・承認画面のターミナルアイコンから、そのセッションを実行している端末を前面に出せる。iTerm2 と Terminal.app では tty を照合して**該当タブまで**選択する。それ以外の端末はアプリの前面化のみ。

### 設定

メニューバーアイコン →**設定…**（`⌘,`）で開く。変更は即時に反映され、`UserDefaults`（`com.piyoraik.AgentNotch`）に保存される。ペインは `⌘1`〜`⌘5` でも切り替えられ、`⌘W` / `Esc` で閉じる。前回開いていたペインを覚える。

| タブ | 変えられるもの |
| --- | --- |
| 一般 | ログイン時に起動、設定のリセット、終了 |
| 表示 | ノッチパネルの表示 / ホバーで展開するか / 折りたたみ時のメーター / 推定コスト / 表示先のディスプレイ / ウィングとパネルのサイズ |
| メニューバー | アイコンの表示 / セッション数のバッジ / メニュー内の使用量とタイトル |
| 承認 | 承認待ちで自動的に開くか / Dock で注意を促すか / サウンド |
| データ更新 | セッション・要約・トランスクリプトのポーリング間隔、使用量の取得可否と間隔 |

ホバー展開をオフにすると、ノッチはクリックしたときだけ開く。メニューバーアイコンとノッチパネルを両方隠した場合でも、`open -a AgentNotch`（または Finder から再度起動）で設定ウィンドウが開く。

## ビルド

```bash
xcodegen generate
xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch \
  -configuration Debug -destination 'platform=macOS' build
```

ビルド成果物は DerivedData に出る。パスは次のコマンドで得られる。

```bash
xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}'
```

`open <上記パス>/AgentNotch.app` で起動する。Dock アイコンは出ない（`LSUIElement`）。**終了はメニューバーアイコン → 「AgentNotch を終了」**から行う。

ブリッジ（`agentnotch-bridge`）は `AgentNotch` の依存になっているので、このスキームをビルドすれば一緒に建ち、`AgentNotch.app/Contents/MacOS/` に入る。

### 配布用にまとめる / 自分のマシンに入れる

```bash
./Scripts/release.sh             # build/AgentNotch-<version>.zip を作る
./Scripts/release.sh --install   # さらに /Applications に入れ替えて起動し直す
```

Release でビルドし、Xcode の ad-hoc 署名が付ける `get-task-allow` を落としてから zip を作る。**バージョンは `project.yml` の `MARKETING_VERSION` だけを直す。** `Info.plist` はそこを参照している。

`--install` は動いている AgentNotch を終了してから `/Applications/AgentNotch.app` を置き換え、**フックが参照しているブリッジのコピーも更新してから**起動し直す。自分でビルドしたものに quarantine は付かないので `xattr` は要らない。

置き換え先に別のアプリがあった場合は `CFBundleIdentifier` が一致しないので中止する。

### アイコン

アイコンは自前のもので、`Design/generate-icon.py` が SVG とアプリアイコンの PNG を書き出す。形を変えるときはスクリプトの定数を直して回す（SVG は生成物なので手で直しても上書きされる）。

```bash
python3 Design/generate-icon.py
```

ラスタライズに Chrome のヘッドレスを使うので、`/Applications/Google Chrome.app` が要る。アイコンを作り直さないなら不要。

パネルの中で Claude Code を指しているマークだけは、Claude.app 同梱の公式トレイアイコンをそのまま使っている（`Resources/Assets.xcassets/ClaudeMark.imageset`）。アプリ自身のマーク（メニューバー・ノッチのピル・設定）とは別物。

## 承認機能のセットアップ

承認をノッチで受けるには、ブリッジの配置とフックの登録が要る。

### 1. ブリッジを配置

ブリッジは `.app` に同梱されている。フックから参照するパスを固定するため、アプリの外に写しておく。

```bash
mkdir -p ~/Library/Application\ Support/AgentNotch/bin
cp /Applications/AgentNotch.app/Contents/MacOS/agentnotch-bridge \
  ~/Library/Application\ Support/AgentNotch/bin/
```

**フックから .app の中を直接指さない。** アプリを移動したり入れ替えたりするとパスが外れ、フックが実行できずに承認のたびにエラーが出る。

ソースからビルドしている場合は、コピー元を `$(xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/AgentNotch.app/Contents/MacOS/agentnotch-bridge` に読み替える。

アプリを更新したときは、このコピーもやり直す。

### 2. フックを登録

`~/.claude/settings.json` の `hooks` に追加する（**編集前にバックアップを取ること**）。

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "'/Users/<you>/Library/Application Support/AgentNotch/bin/agentnotch-bridge'",
            "timeout": 150
          }
        ]
      }
    ]
  }
}
```

登録後は、普段どおり `claude` を起動するだけでよい。特別なフラグは要らない。

### フェイルセーフ

AgentNotch が起動していない場合、ブリッジは **0.5 秒以内に終了コード 0・出力なし**で抜ける。これは「判断しない」と解釈され、通常どおりターミナルに承認プロンプトが出る。**アプリの不在や不具合でセッションがハングすることはない。**

ノッチ側で 120 秒応答がない場合も同様にターミナルへ委譲される。

## プライバシー

- セッション情報・トランスクリプトはすべてローカルのファイルから読む。外部に送信しない。
- ネットワーク通信は使用量エンドポイント（`api.anthropic.com/api/oauth/usage`）への参照のみ。認証には `claude` CLI が保存済みの OAuth トークンを使う。
- 承認のやり取りはローカルの Unix ドメインソケット内で完結する。

## 制限

- 承認できるのは**ツールの許可 / 拒否**まで。`AskUserQuestion` の選択肢やプラン承認はフックの対象外で、ターミナルで答える必要がある。
- ノッチは MacBook 内蔵ディスプレイにしかない。外部ディスプレイで作業している場合、常用の入口はメニューバーアイコンになる。
- ターミナルのタブ特定に対応しているのは iTerm2 と Terminal.app のみ。初回はシステムの自動化許可ダイアログが出る。
- 配布している `.app` は未署名・未公証。初回に quarantine を外す手間がかかるほか、署名が更新ごとに変わるため、ターミナルの自動化許可を入れ直すよう求められることがある。
