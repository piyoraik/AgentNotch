#!/bin/bash
#
# 配布用の AgentNotch.app を Release でビルドし、zip に固めて build/ に置く。
#
#   ./Scripts/release.sh             zip を作るだけ
#   ./Scripts/release.sh --install   さらに /Applications に入れ替えて起動し直す
#
# 署名は ad-hoc のまま。Developer ID を持っていないため公証も通していないので、
# 受け取った側は quarantine 属性を外す必要がある（手順は README）。
# 自分でビルドしたものには quarantine が付かないので --install には要らない。
set -euo pipefail

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "知らない引数: $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

BUNDLE_ID="com.piyoraik.AgentNotch"
# 差し替え先。rm -rf する相手なので、上書きできるのは入れ替え先の確認を
# テストするためだけ。どちらの経路でも CFBundleIdentifier は必ず照合する。
DEST="${AGENTNOTCH_DEST:-/Applications/AgentNotch.app}"
BRIDGE_DIR="$HOME/Library/Application Support/AgentNotch/bin"

echo "==> xcodegen generate"
xcodegen generate >/dev/null

echo "==> Release ビルド"
# ブリッジは AgentNotch の依存なので、このスキームだけで両方が建つ。
xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch \
  -configuration Release -destination 'platform=macOS' build >/dev/null

PRODUCTS="$(xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch \
  -configuration Release -showBuildSettings 2>/dev/null |
  awk '/ BUILT_PRODUCTS_DIR /{print $3}')"
APP="$PRODUCTS/AgentNotch.app"

test -d "$APP" || { echo "ビルド結果が見つからない: $APP" >&2; exit 1; }
test -x "$APP/Contents/MacOS/agentnotch-bridge" || {
  echo "ブリッジが同梱されていない。project.yml の dependencies を確認する" >&2
  exit 1
}

VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)"
echo "==> AgentNotch $VERSION ($BUILD)"

# Xcode の ad-hoc 署名には com.apple.security.get-task-allow が付く。
# デバッガの接続を許すエンタイトルメントなので、配る前に署名し直して落とす。
# 入れ子のバイナリが先、器が後。
echo "==> 署名し直し（get-task-allow を落とす）"
codesign --force --sign - "$APP/Contents/MacOS/agentnotch-bridge"
codesign --force --sign - "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "get-task-allow が残っている" >&2
  exit 1
fi

mkdir -p build
ZIP="build/AgentNotch-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sig"
echo "==> $ZIP"
# ditto を使うのは、zip(1) と違って拡張属性とシンボリックリンクを壊さないため。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# アプリ内の自動更新はこの署名だけを信頼する。GitHub が配ったという事実は
# 根拠にしていないので、署名の無い zip をリリースに載せない。
echo "==> 署名"
swift Scripts/signing.swift sign "$ZIP" >/dev/null
PUBKEY="$(awk -F'"' '/publicKeyBase64 = /{print $2}' Sources/AgentNotch/Services/ReleaseSignature.swift)"
swift Scripts/signing.swift verify "$ZIP" "$ZIP.sig" "$PUBKEY" >/dev/null
echo "    アプリに埋まっている公開鍵で検証できた"

if [ "$INSTALL" -eq 0 ]; then
  echo
  echo "できたもの: $ZIP"
  echo "            $ZIP.sig"
  echo "リリースに載せる: gh release upload v$VERSION $ZIP $ZIP.sig"
  echo "自分のマシンに入れる: $0 --install"
  exit 0
fi

# ここから --install。既に入っているものを消すので、消す相手を必ず確かめる。
if [ -e "$DEST" ]; then
  EXISTING="$(defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "")"
  if [ "$EXISTING" != "$BUNDLE_ID" ]; then
    echo "$DEST は AgentNotch ではない（CFBundleIdentifier: ${EXISTING:-読めない}）。消さずに中止する。" >&2
    exit 1
  fi
fi

# 動いたまま差し替えると、古いプロセスが消えたバンドルを掴んだままになる。
if pgrep -f "AgentNotch.app/Contents/MacOS/AgentNotch" >/dev/null; then
  echo "==> 動いている AgentNotch を終了"
  pkill -f "AgentNotch.app/Contents/MacOS/AgentNotch" || true
  for _ in $(seq 20); do
    pgrep -f "AgentNotch.app/Contents/MacOS/AgentNotch" >/dev/null || break
    sleep 0.25
  done
fi

echo "==> $DEST に入れ替え"
rm -rf "$DEST"
ditto "$APP" "$DEST"

# フックが指しているのはアプリの外のコピー。アプリだけ入れ替えると
# 古いブリッジが残るので、ここで必ず揃える。
echo "==> ブリッジを更新: $BRIDGE_DIR"
mkdir -p "$BRIDGE_DIR"
ditto "$DEST/Contents/MacOS/agentnotch-bridge" "$BRIDGE_DIR/agentnotch-bridge"

echo "==> 起動"
open "$DEST"

echo
echo "AgentNotch $VERSION ($BUILD) を $DEST に入れた。"
echo "Dock には出ない。メニューバーのアイコンとノッチで確認する。"
