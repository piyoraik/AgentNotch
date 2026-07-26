#!/bin/bash
#
# 配布用の AgentNotch.app を Release でビルドし、zip に固めて build/ に置く。
#
#   ./Scripts/release.sh
#
# 署名は ad-hoc のまま。Developer ID を持っていないため公証も通していないので、
# 受け取った側は quarantine 属性を外す必要がある（手順は README）。
set -euo pipefail

cd "$(dirname "$0")/.."

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
rm -f "$ZIP"
echo "==> $ZIP"
# ditto を使うのは、zip(1) と違って拡張属性とシンボリックリンクを壊さないため。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "できたもの: $ZIP"
echo "リリースに載せる: gh release upload v$VERSION $ZIP"
