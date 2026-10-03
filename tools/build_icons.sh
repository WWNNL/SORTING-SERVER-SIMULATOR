#!/bin/bash
# 重新生成三份图标文件：icon.svg（编辑器/窗口图标）、icon.ico（Windows）、
# icon.icns（macOS）。改图标只需改 tools/make_icon.py 里的像素设计，然后跑这个。
#
#   tools/build_icons.sh
#
# 尺寸分档见 tools/make_icon.py 的说明：16/32/48 用粗放版网格，64 以上用
# 细密版。两套网格的尺寸档都是整数倍，所以这里永远不做非整数缩放。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$GODOT" ]; then
	echo "找不到 Godot：$GODOT" >&2
	echo "用 GODOT=/path/to/Godot tools/build_icons.sh 指定。" >&2
	exit 1
fi

echo "== 生成 SVG"
python3 "$ROOT/tools/make_icon.py" svg big "$ROOT/icon.svg"
python3 "$ROOT/tools/make_icon.py" svg small "$TMP/icon_small.svg"

echo "== 光栅化"
"$GODOT" --headless --path "$ROOT" --script "$ROOT/tools/rasterize_icon.gd" -- \
	"$ROOT/icon.svg" 64 "$TMP/big" 64,128,256,512,1024
"$GODOT" --headless --path "$ROOT" --script "$ROOT/tools/rasterize_icon.gd" -- \
	"$TMP/icon_small.svg" 16 "$TMP/small" 16,32,48

echo "== 打包 ico（Windows）"
python3 "$ROOT/tools/make_icon.py" ico "$ROOT/icon.ico" \
	16:"$TMP/small/icon_16.png" \
	32:"$TMP/small/icon_32.png" \
	48:"$TMP/small/icon_48.png" \
	64:"$TMP/big/icon_64.png" \
	128:"$TMP/big/icon_128.png" \
	256:"$TMP/big/icon_256.png"

echo "== 打包 icns（macOS）"
ICONSET="$TMP/icon.iconset"
mkdir -p "$ICONSET"
cp "$TMP/small/icon_16.png"  "$ICONSET/icon_16x16.png"
cp "$TMP/small/icon_32.png"  "$ICONSET/icon_16x16@2x.png"
cp "$TMP/small/icon_32.png"  "$ICONSET/icon_32x32.png"
cp "$TMP/big/icon_64.png"    "$ICONSET/icon_32x32@2x.png"
cp "$TMP/big/icon_128.png"   "$ICONSET/icon_128x128.png"
cp "$TMP/big/icon_256.png"   "$ICONSET/icon_128x128@2x.png"
cp "$TMP/big/icon_256.png"   "$ICONSET/icon_256x256.png"
cp "$TMP/big/icon_512.png"   "$ICONSET/icon_256x256@2x.png"
cp "$TMP/big/icon_512.png"   "$ICONSET/icon_512x512.png"
cp "$TMP/big/icon_1024.png"  "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$ROOT/icon.icns"

echo "== 完成"
ls -la "$ROOT/icon.svg" "$ROOT/icon.ico" "$ROOT/icon.icns"
