#!/usr/bin/env python3
"""AgentNotch のアイコンを生成する。

    python3 Design/generate-icon.py

やること 2 つ。

1. `Design/AgentNotchIcon.svg`（タイル付きのアプリアイコン）と
   `Design/AgentNotchMark.svg`（マーク単体）を書き出す。
2. その SVG を各サイズに焼いて `Resources/Assets.xcassets/AppIcon.appiconset/`
   に置く。

SVG を手で直したあとにこのスクリプトを回すと上書きされる。**形を変えるときは
下の定数を直してから走らせる。** 円弧の座標を手計算しないための仕組みなので、
SVG 側だけを直す運用にしない。

比率（`R` / `W` / `PUPIL` を `OUTER` で割った値）は
`Sources/AgentNotch/Views/AgentMark.swift` の `AgentMark` が持つ定数と同じもの。
片方だけ変えるとアイコンと UI のマークが違う形になる。

ラスタライズは Chrome のヘッドレスに任せている。librsvg も ImageMagick も
入っていない環境で、透過を保ったまま SVG を焼ける手段がこれだけだったため。
"""
import math
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DESIGN = ROOT / "Design"
ICONSET = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset"

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# (ファイル名, ピクセル数)。Contents.json の 10 スロットと 1 対 1 に対応する。
# ピクセル数が同じスロット（16x16@2x と 32x32 など）でもファイルは分けておく。
# 中身は同じだが、どのスロットが埋まっているかが名前で分かる。
#
# 参考: ビルドすると `AppIcon.icns` と `Assets.car` の両方が出るが、
# **`.icns` には 16/32/128/256 しか入らない**（actool が意図的に削る旧形式の
# フォールバック）。1024 まで入っているのは `Assets.car` のほうで、macOS 11 以降は
# `CFBundleIconName` を見てそちらを読む。`.icns` に大きいサイズが無いのを見て
# ここのスロットを増やしても意味がない。
SLOTS = [
    ("icon_16.png", 16),
    ("icon_16@2x.png", 32),
    ("icon_32.png", 32),
    ("icon_32@2x.png", 64),
    ("icon_128.png", 128),
    ("icon_128@2x.png", 256),
    ("icon_256.png", 256),
    ("icon_256@2x.png", 512),
    ("icon_512.png", 512),
    ("icon_512@2x.png", 1024),
]

# --- 形 -------------------------------------------------------------------
C = 512.0          # 1024 キャンバスの中心
R = 250.0          # 輪の中心線の半径
W = 108.0          # 輪の太さ
OUTER = R + W / 2  # 304 = マーク自身の外周半径
PUPIL = 96.0       # 瞳
GAP = 84.0         # 上部の開口部。これがノッチ
FILL = 0.68        # メーターが埋まっている割合。読み取れる値ではなく飾り

SPAN = 360.0 - GAP           # 276
START = -90.0 + GAP / 2      # -48 = 開口部の右端
PROGRESS = SPAN * FILL       # 187.68

# --- 色 -------------------------------------------------------------------
# 寒色が通常、暖色が注意。AgentBrand と揃える。
MINT = "#5FE3CF"
SKY = "#3FBFE8"
AZURE = "#4A7CFF"


def pt(angle_deg, radius, cx=C, cy=C):
    a = math.radians(angle_deg)
    return cx + radius * math.cos(a), cy + radius * math.sin(a)


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def arc(angle_from, angle_to, radius, cx=C, cy=C):
    """時計回りの円弧。ストローク前提のパス。"""
    x0, y0 = pt(angle_from, radius, cx, cy)
    x1, y1 = pt(angle_to, radius, cx, cy)
    large = 1 if abs(angle_to - angle_from) > 180 else 0
    return (f"M {f(x0)} {f(y0)} "
            f"A {f(radius)} {f(radius)} 0 {large} 1 {f(x1)} {f(y1)}")


def icon_svg():
    gx0, gy0 = pt(START, R)
    gx1, gy1 = pt(START + PROGRESS, R)
    px, py = pt(START + PROGRESS, R)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>AgentNotch</title>
  <!-- 生成物。Design/generate-icon.py が書き出す。
       メーターの円弧と瞳を重ねた形で、上の開口部がノッチ。欠けた輪が
       「見張っている目」に見えるのを狙っている。
       タイルは 1024 のうち 824（macOS の慣習どおり）。 -->
  <defs>
    <linearGradient id="tile" x1="512" y1="100" x2="512" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#28304A"/>
      <stop offset="1" stop-color="#0B0E16"/>
    </linearGradient>
    <linearGradient id="rim" x1="512" y1="100" x2="512" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.24"/>
      <stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0.05"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.02"/>
    </linearGradient>
    <radialGradient id="bloom" cx="512" cy="470" r="360" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{MINT}" stop-opacity="0.26"/>
      <stop offset="1" stop-color="{MINT}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="arc" x1="{f(gx0)}" y1="{f(gy0)}" x2="{f(gx1)}" y2="{f(gy1)}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{AZURE}"/>
      <stop offset="0.5" stop-color="{SKY}"/>
      <stop offset="1" stop-color="{MINT}"/>
    </linearGradient>
    <linearGradient id="pupil" x1="{f(C - PUPIL)}" y1="{f(C - PUPIL)}" x2="{f(C + PUPIL)}" y2="{f(C + PUPIL)}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{MINT}"/>
      <stop offset="1" stop-color="{AZURE}"/>
    </linearGradient>
    <radialGradient id="pupilGlow" cx="512" cy="512" r="{f(PUPIL * 1.9)}" gradientUnits="userSpaceOnUse">
      <stop offset="0.35" stop-color="{MINT}" stop-opacity="0.20"/>
      <stop offset="1" stop-color="{MINT}" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="tileClip">
      <rect x="100" y="100" width="824" height="824" rx="185"/>
    </clipPath>
  </defs>

  <!-- タイル -->
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#tile)"/>
  <g clip-path="url(#tileClip)">
    <circle cx="512" cy="470" r="360" fill="url(#bloom)"/>
  </g>
  <rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="url(#rim)" stroke-width="3"/>

  <!-- メーター。薄い輪が全体、明るい円弧が現在値 -->
  <g fill="none">
    <path d="{arc(START, START + SPAN, R)}" stroke="#FFFFFF" stroke-opacity="0.13" stroke-width="{f(W)}" stroke-linecap="round"/>
    <path d="{arc(START, START + PROGRESS, R)}" stroke="url(#arc)" stroke-width="{f(W)}" stroke-linecap="round"/>
  </g>

  <!-- 現在値の先端 -->
  <circle cx="{f(px)}" cy="{f(py)}" r="30" fill="#F4FFFB"/>

  <!-- 瞳。わずかに光らせてタイルの上に浮かせる -->
  <circle cx="512" cy="512" r="{f(PUPIL * 1.9)}" fill="url(#pupilGlow)"/>
  <circle cx="512" cy="512" r="{f(PUPIL)}" fill="url(#pupil)"/>
</svg>
"""


def mark_svg():
    """タイルなしのマーク。README やメニューバーの参考用。

    輪の外周が viewBox に接するので、そのまま並べても余白が出ない。
    """
    s = 128.0 / OUTER
    cx = cy = 128.0
    gx0, gy0 = pt(START, R * s, cx, cy)
    gx1, gy1 = pt(START + PROGRESS, R * s, cx, cy)
    px, py = pt(START + PROGRESS, R * s, cx, cy)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
  <title>AgentNotch mark</title>
  <!-- 生成物。Design/generate-icon.py が書き出す。 -->
  <defs>
    <linearGradient id="markArc" x1="{f(gx0)}" y1="{f(gy0)}" x2="{f(gx1)}" y2="{f(gy1)}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{AZURE}"/>
      <stop offset="0.5" stop-color="{SKY}"/>
      <stop offset="1" stop-color="{MINT}"/>
    </linearGradient>
  </defs>
  <g fill="none">
    <path d="{arc(START, START + SPAN, R * s, cx, cy)}" stroke="#FFFFFF" stroke-opacity="0.16" stroke-width="{f(W * s)}" stroke-linecap="round"/>
    <path d="{arc(START, START + PROGRESS, R * s, cx, cy)}" stroke="url(#markArc)" stroke-width="{f(W * s)}" stroke-linecap="round"/>
  </g>
  <circle cx="{f(px)}" cy="{f(py)}" r="{f(30 * s)}" fill="#F2FFFC"/>
  <circle cx="128" cy="128" r="{f(PUPIL * s)}" fill="url(#markArc)"/>
</svg>
"""


def rasterize(svg: pathlib.Path, size: int, out: pathlib.Path, tmp: pathlib.Path):
    """Chrome に SVG を透過つきで焼かせる。

    `--window-size` はスクロールせず切り取るだけなので、目的のサイズに縮めた
    `<img>` を挟む。SVG を直接開くと常に intrinsic size で描かれてしまう。
    """
    wrapper = tmp / f"wrap{size}.html"
    wrapper.write_text(
        '<body style="margin:0;padding:0;overflow:hidden">'
        f'<img src="{svg}" width="{size}" height="{size}" style="display:block"></body>'
    )
    subprocess.run(
        [CHROME, "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
         "--force-device-scale-factor=1", "--default-background-color=00000000",
         f"--screenshot={out}", f"--window-size={size},{size}", wrapper.as_uri()],
        check=True, capture_output=True,
    )


def main():
    DESIGN.mkdir(exist_ok=True)
    (DESIGN / "AgentNotchIcon.svg").write_text(icon_svg())
    (DESIGN / "AgentNotchMark.svg").write_text(mark_svg())
    print(f"wrote {DESIGN / 'AgentNotchIcon.svg'}")
    print(f"wrote {DESIGN / 'AgentNotchMark.svg'}")

    if not pathlib.Path(CHROME).exists():
        print(f"Chrome が見つからないので PNG は作らなかった: {CHROME}", file=sys.stderr)
        return 1

    ICONSET.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        for name, size in SLOTS:
            out = ICONSET / name
            rasterize(DESIGN / "AgentNotchIcon.svg", size, out, tmp)
            print(f"wrote {out} ({size}px)")
    print("Contents.json は手で持っている。スロットを増やすときはそちらも足す。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
