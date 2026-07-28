#!/bin/bash
# ドキュメント用のスクリーンショットを撮る。
#
#   ./Scripts/capture-docs.sh                  # 台本どおり順に撮る（通常はこれ）
#   ./Scripts/capture-docs.sh 02-sessions      # 1 枚だけ撮り直す
#   ./Scripts/capture-docs.sh 02-sessions 10   # 待ち時間を伸ばす
#   ./Scripts/capture-docs.sh --list           # 台本を見る
#
# ノッチのパネルはホバーでしか開かないため、必ずタイマー越しに撮る。
# screencapture -w（ウィンドウ選択）はクリックした時点でパネルが閉じるので使えない。
#
# 画面全体を撮る。切り出しは受け取ってから行うので、範囲は気にしなくてよい。
# 撮る前に、映って困るウィンドウを片付けること。
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
outdir="$root/docs/images/raw"
display="${AGENTNOTCH_CAPTURE_DISPLAY:-1}"

# name<TAB>待ち秒<TAB>作ってほしい状態
# 承認まわり（04/05/06）はここに無い。承認要求を出す側と組んで撮るため。
shots=$(cat <<'SHOTS'
01-pill	5	カーソルをノッチから離し、畳まれたピルが見える状態にする
02-sessions	6	ノッチにカーソルを乗せてパネルを開いたまま待つ
03-detail	8	ノッチを開き、いちばん上のセッション行をクリックして詳細を出す
15-menubar-menu	6	メニューバーの輪のアイコンをクリックし、メニューを開いたまま待つ
08-usage-report	8	メニューから「使用状況レポート…」を開く
14-history	10	⌘Y で履歴を開き、適当な 1 本を選んで本文を出す
10-settings-display	8	⌘, で設定を開き、⌘2 で「表示」ペインにする
13-settings-notify	6	設定のまま ⌘4 で「通知」ペインにする
07-always-allow	8	設定を閉じ、ノッチを開いてヘッダーの盾バッジをクリックする
SHOTS
)

capture() {
  local name="$1" delay="$2"
  local out="$outdir/$name.png"
  mkdir -p "$outdir"

  local i
  for ((i = delay; i > 0; i--)); do
    printf "\r  \033[33m%2d\033[0m 秒後に撮ります " "$i"
    sleep 1
  done
  printf "\r%*s\r" 40 ""

  screencapture -x -D "$display" "$out"

  if [ ! -f "$out" ]; then
    echo "  失敗: $name — 画面収録の権限か、ディスプレイ番号を確認する" >&2
    return 1
  fi
  echo "  保存: docs/images/raw/$name.png"
}

case "${1:-}" in
  --list)
    printf '%s\n' "$shots" | awk -F'\t' '{printf "  %-20s %s\n", $1, $3}'
    exit 0
    ;;
  --help | -h)
    sed -n '2,10p' "$0"
    exit 0
    ;;
  "")
    ;;
  *)
    capture "$1" "${2:-5}"
    exit $?
    ;;
esac

# 台本モード
total=$(printf '%s\n' "$shots" | wc -l | tr -d ' ')
echo "ドキュメント用の撮影を $total 枚ぶん行います。"
echo "映って困るウィンドウは先に片付けてください。画面全体を撮ります。"
echo "各ステップは Enter で開始、s で飛ばし、q で中止です。"
echo

n=0
done_list=()
skipped=()
while IFS=$'\t' read -r name delay hint; do
  n=$((n + 1))
  echo "[$n/$total] $name"
  echo "  $hint"
  printf "  Enter=撮る / s=飛ばす / q=中止 > "
  # while の stdin は台本を読んでいるので、端末から読み直す。
  answer=""
  if ! read -r answer </dev/tty; then
    echo
    echo "端末が見つかりません。Terminal.app か iTerm2 のウィンドウで直接実行してください。" >&2
    echo "（Claude Code の ! やパイプ越しでは、カウントダウンを見ながら状態を作れません）" >&2
    exit 1
  fi
  case "$answer" in
    q | Q)
      echo "中止しました。"
      break
      ;;
    s | S)
      echo "  飛ばしました。"
      skipped+=("$name")
      ;;
    *)
      if capture "$name" "$delay"; then
        done_list+=("$name")
      else
        skipped+=("$name")
      fi
      ;;
  esac
  echo
done <<< "$shots"

echo "撮れた: ${#done_list[@]} 枚"
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "撮れなかった: ${skipped[*]}"
  echo "1 枚だけ撮り直すには ./Scripts/capture-docs.sh <名前> [待ち秒]"
fi
