#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
LIVE="$HOME/.local/share/omacosy/helper/vapor-sys-saver"
SAVER_DST="$HOME/Library/Screen Savers/OmacosyVapor.saver"
RAIN_DST="$HOME/Library/Screen Savers/OmacosyRain.saver"
PLIST="$HOME/Library/LaunchAgents/com.omacosy.vapor-engine.plist"
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
[[ -n "$SDK" ]] || SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
CC="${CLANG:-/usr/bin/clang}"

mkdir -p "$HOME/Library/Screen Savers" "$LIVE"
rsync -a --delete --exclude '.DS_Store' "$SRC/" "$LIVE/" || true

TMP="$(mktemp -d)"
BUNDLE="$TMP/OmacosyVapor.saver"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
"$CC" -bundle -fobjc-arc -O2 -isysroot "$SDK" \
  -framework Cocoa -framework ScreenSaver \
  -o "$BUNDLE/Contents/MacOS/OmacosyVapor" \
  "$SRC/OmacosyVaporView.m"
cp "$SRC/Info-saver.plist" "$BUNDLE/Contents/Info.plist"
PREVIEW="$SRC/../oligarchy-screensaver/share/preview.png"
if [[ -f "$PREVIEW" ]]; then
  cp "$PREVIEW" "$BUNDLE/Contents/Resources/preview.png"
  python3 - "$PREVIEW" "$BUNDLE/Contents/Resources/thumbnail.png" <<'PY'
import random, sys
from pathlib import Path
try:
    from PIL import Image
except ImportError:
    Path(sys.argv[2]).write_bytes(Path(sys.argv[1]).read_bytes())
    raise SystemExit(0)
src = Image.open(sys.argv[1]).convert("RGB")
out = Image.new("RGB", src.size, (0, 0, 0))
sp, op = src.load(), out.load()
w, h = src.size
step = 16
parts = []
for y in range(0, h, step):
    for x in range(0, w, step):
        r, g, b = sp[x, y]
        if r + g + b > 40:
            parts.append((x, y, r, g, b))
rnd = random.Random(20)
for x, y, r, g, b in parts:
    if rnd.random() < 0.82:
        nx = x + int(rnd.uniform(-520, 520))
        ny = y + int(rnd.uniform(-300, 300))
    else:
        nx, ny = x, y
    for dy in range(step):
        for dx in range(step):
            xx, yy = nx + dx, ny + dy
            if 0 <= xx < w and 0 <= yy < h:
                op[xx, yy] = (r, g, b)
out.resize((960, 540), Image.NEAREST).save(sys.argv[2])
PY
fi
codesign -f -s - --identifier com.omacosy.vapor-jump "$BUNDLE" >/dev/null 2>&1 || true
rm -rf "$SAVER_DST"
cp -R "$BUNDLE" "$SAVER_DST"
codesign -f -s - --identifier com.omacosy.vapor-jump "$SAVER_DST" >/dev/null 2>&1 || true
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -u "$SAVER_DST" >/dev/null 2>&1 || true
"$LSREG" -f "$SAVER_DST" >/dev/null 2>&1 || true
rm -rf "$TMP"

UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}/com.omacosy.vapor-engine" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
killall omacosy-vapor-engine 2>/dev/null || true

if [[ ! -d "$RAIN_DST" ]]; then
  echo "warning: OmacosyRain.saver is missing; this build does not recreate it" >&2
fi
echo "installed $SAVER_DST"
echo "kept $RAIN_DST"
