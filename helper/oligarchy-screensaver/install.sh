#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
LIVE="$HOME/.local/share/omacosy/helper/oligarchy-screensaver"
BIN="$HOME/.local/bin"
BRAND="$HOME/.config/omarchy/branding"

mkdir -p "$LIVE" "$BIN" "$BRAND"
python3 "$SRC/share/make_vapor_logo.py"
rsync -a --delete --exclude '.DS_Store' --exclude '*.upstream' "$SRC/" "$LIVE/" || true
chmod +x "$LIVE/bin/"*

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk"
if [ ! -d "$SDK" ]; then
  SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"
fi
if [ -z "${SWIFTC:-}" ]; then
  for c in \
    /opt/homebrew/opt/swift/Swift-6.3.xctoolchain/usr/bin/swiftc \
    /opt/homebrew/opt/swift/bin/swiftc \
    /usr/bin/swiftc
  do
    if [ -x "$c" ]; then SWIFTC="$c"; break; fi
  done
fi
SWIFTC="${SWIFTC:-swiftc}"
"$SWIFTC" -O -sdk "$SDK" -F /System/Library/PrivateFrameworks -framework SkyLight \
  -o "$BIN/omacosy-ss-guard" "$SRC/bin/omacosy-ss-guard.swift"
"$SWIFTC" -O -sdk "$SDK" -o "$BIN/omacosy-session-locked" "$SRC/bin/omacosy-session-locked.swift"
codesign -f -s - --identifier com.omacosy.ss-guard "$BIN/omacosy-ss-guard" >/dev/null 2>&1 || true
cp "$BIN/omacosy-ss-guard" "$LIVE/bin/omacosy-ss-guard"
cp "$BIN/omacosy-session-locked" "$LIVE/bin/omacosy-session-locked"

install_ttfx() {
  if command -v ttfx >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v cargo >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
    brew install rust
  fi
  if command -v cargo >/dev/null 2>&1; then
    cargo install ttfx --locked --root "$HOME/.local"
  fi
}
install_ttfx || true

ln -sfn "$LIVE/bin/omacosy-screensaver" "$BIN/omacosy-screensaver"
ln -sfn "$LIVE/bin/omacosy-launch-screensaver" "$BIN/omacosy-launch-screensaver"
ln -sfn "$LIVE/bin/oligarchy-screensaver-text" "$BIN/oligarchy-screensaver-text"
ln -sfn "$LIVE/bin/omacosy-screensaver-idle" "$BIN/omacosy-screensaver-idle"

# Ghostty is the real screensaver. Keep the .saver installed but never let
# System Settings start it on idle.
defaults -currentHost write com.apple.screensaver idleTime -int 0 >/dev/null 2>&1 || true

AGENT_SRC="$SRC/com.omacosy.ghostty-screensaver.plist"
AGENT_DST="$HOME/Library/LaunchAgents/com.omacosy.ghostty-screensaver.plist"
cp "$AGENT_SRC" "$AGENT_DST"
UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}/com.omacosy.ghostty-screensaver" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$AGENT_DST" 2>/dev/null || launchctl load "$AGENT_DST" 2>/dev/null || true
if [[ -x "$HOME/Library/Python/3.14/bin/tte" ]]; then
  ln -sfn "$HOME/Library/Python/3.14/bin/tte" "$BIN/tte"
fi

OLIGARCHY_DATA_DIR="$LIVE/share" \
OLIGARCHY_SCREENSAVER_TXT="$BRAND/screensaver.txt" \
  "$LIVE/bin/oligarchy-screensaver-text"

echo "installed $LIVE"
echo "wrote $BRAND/screensaver.txt"
