# ClaudeNotch

Mac のノッチとメニューバーから Claude Code のセッションを監視し、承認に応答するためのネイティブ macOS アプリ。

ターミナルで普段どおり `claude` を起動するだけで、実行中のセッション・トークン消費・レート制限の残量がノッチに表示され、ツールの承認要求をノッチから直接さばける。

## 必要環境

- macOS 14 以降
- Xcode 26 以降（`xcodebuild` が使えること）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

ノッチのある内蔵ディスプレイがなくても動作する。その場合はメニューバー中央に同等のピルを表示する。

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

### ターミナルへのジャンプ

一覧・詳細・承認画面のターミナルアイコンから、そのセッションを実行している端末を前面に出せる。iTerm2 と Terminal.app では tty を照合して**該当タブまで**選択する。それ以外の端末はアプリの前面化のみ。

### 設定

メニューバーアイコン →**設定…**（`⌘,`）で開く。変更は即時に反映され、`UserDefaults`（`com.piyoraik.ClaudeNotch`）に保存される。

| タブ | 変えられるもの |
| --- | --- |
| 表示 | ノッチパネルの表示 / ホバーで展開するか / 折りたたみ時のメーター / ウィングとパネルのサイズ |
| メニューバー | アイコンの表示 / セッション数のバッジ / メニュー内の使用量とタイトル |
| 更新 | セッション・要約・トランスクリプトのポーリング間隔、使用量の取得可否と間隔 |
| 承認 | 承認待ちで自動的に開くか / Dock で注意を促すか / サウンド |
| 一般 | ログイン時に起動、設定のリセット、終了 |

ホバー展開をオフにすると、ノッチはクリックしたときだけ開く。メニューバーアイコンとノッチパネルを両方隠した場合でも、`open -a ClaudeNotch`（または Finder から再度起動）で設定ウィンドウが開く。

## ビルド

```bash
xcodegen generate
xcodebuild -project ClaudeNotch.xcodeproj -scheme ClaudeNotch \
  -configuration Debug -destination 'platform=macOS' build
```

ビルド成果物は DerivedData に出る。パスは次のコマンドで得られる。

```bash
xcodebuild -project ClaudeNotch.xcodeproj -scheme ClaudeNotch \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}'
```

`open <上記パス>/ClaudeNotch.app` で起動する。Dock アイコンは出ない（`LSUIElement`）。**終了はメニューバーアイコン → 「ClaudeNotch を終了」**から行う。

## 承認機能のセットアップ

承認をノッチで受けるには、ブリッジの配置とフックの登録が要る。

### 1. ブリッジを配置

```bash
xcodebuild -project ClaudeNotch.xcodeproj -scheme claudenotch-bridge \
  -configuration Debug -destination 'platform=macOS' build

mkdir -p ~/Library/Application\ Support/ClaudeNotch/bin
cp "$(xcodebuild -project ClaudeNotch.xcodeproj -scheme claudenotch-bridge \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/claudenotch-bridge" \
  ~/Library/Application\ Support/ClaudeNotch/bin/
```

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
            "command": "'/Users/<you>/Library/Application Support/ClaudeNotch/bin/claudenotch-bridge'",
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

ClaudeNotch が起動していない場合、ブリッジは **0.5 秒以内に終了コード 0・出力なし**で抜ける。これは「判断しない」と解釈され、通常どおりターミナルに承認プロンプトが出る。**アプリの不在や不具合でセッションがハングすることはない。**

ノッチ側で 120 秒応答がない場合も同様にターミナルへ委譲される。

## プライバシー

- セッション情報・トランスクリプトはすべてローカルのファイルから読む。外部に送信しない。
- ネットワーク通信は使用量エンドポイント（`api.anthropic.com/api/oauth/usage`）への参照のみ。認証には `claude` CLI が保存済みの OAuth トークンを使う。
- 承認のやり取りはローカルの Unix ドメインソケット内で完結する。

## 制限

- 承認できるのは**ツールの許可 / 拒否**まで。`AskUserQuestion` の選択肢やプラン承認はフックの対象外で、ターミナルで答える必要がある。
- ノッチは MacBook 内蔵ディスプレイにしかない。外部ディスプレイで作業している場合、常用の入口はメニューバーアイコンになる。
- ターミナルのタブ特定に対応しているのは iTerm2 と Terminal.app のみ。初回はシステムの自動化許可ダイアログが出る。
