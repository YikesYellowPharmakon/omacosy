#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$HOME/.local/share/omacosy}"
BIN="$HOME/.local/bin/omacosy-matrix-rain"
SAVER_DST="$HOME/Library/Screen Savers/OmacosyRain.saver"
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
[[ -n "$SDK" ]] || SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
mkdir -p "$(dirname "$BIN")" "$SRC"

# Command Line Tools have no `metal` compiler. The app compiles matrix.metal
# at runtime with MTLDevice newLibraryWithSource, which is the Omarchy shader.
CC="${CLANG:-/usr/bin/clang}"
"$CC" -fobjc-arc -O2 -isysroot "$SDK" \
  -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore -framework CoreImage -framework CoreGraphics \
  -o "$BIN" \
  "$SRC/MatrixRain.m" "$SRC/desktop_main.m"
codesign -f -s - --identifier com.omacosy.matrix-rain "$BIN" >/dev/null 2>&1 || true

TMP="$(mktemp -d)"
mkdir -p "$TMP/OmacosyRain.saver/Contents/MacOS" "$TMP/OmacosyRain.saver/Contents/Resources"
"$CC" -bundle -fobjc-arc -O2 -isysroot "$SDK" \
  -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore -framework CoreImage -framework CoreGraphics -framework ScreenSaver \
  -o "$TMP/OmacosyRain.saver/Contents/MacOS/OmacosyRain" \
  "$SRC/MatrixRain.m" "$SRC/OmacosyRainView.m"
cp "$SRC/Info-saver.plist" "$TMP/OmacosyRain.saver/Contents/Info.plist"
cp "$SRC/glyphs.png" "$SRC/matrix.metal" "$TMP/OmacosyRain.saver/Contents/Resources/"
mkdir -p "$HOME/Library/Screen Savers"
rm -rf "$SAVER_DST"
cp -R "$TMP/OmacosyRain.saver" "$SAVER_DST"
rm -rf "$TMP"
echo "built $BIN"
echo "installed $SAVER_DST"
