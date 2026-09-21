#!/usr/bin/env bash
# Drop Sequoia's frozen third-party screensaver preview and reload the plugin.
set -euo pipefail

SAVER="$HOME/Library/Screen Savers/OmacosyVapor.saver"
CACHE="$HOME/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/screenSaver-"
HOST_ID="6A8724F3-55F3-51D2-85CE-5C230E2C6343"
HOST_PLIST="$HOME/Library/Preferences/ByHost/com.apple.screensaver.${HOST_ID}.plist"

# 1) Unload whatever Settings already has mapped.
killall -9 "legacyScreenSaver" "ScreenSaverEngine" 2>/dev/null || true
killall -9 "System Settings" 2>/dev/null || true
killall -9 "legacyScreenSaver" 2>/dev/null || true
sleep 0.4

# 2) Delete the WallpaperAgent preview tree for our saver (and the empty parent dirs).
rm -rf "$CACHE/Users/ye/Library/Screen Savers/OmacosyVapor.saver"
rm -rf "$CACHE/Users/ye/Library/Screen Savers/OmarchyVapor.saver"
rm -f "$HOME/Library/Logs/omacosy-vapor-jump.log"
rm -f "$HOME/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/vapor-saver.log"

# 3) Point idle screensaver at the replacement bundle.
defaults -currentHost write com.apple.screensaver moduleDict -dict \
  moduleName "Omarchy Vapor" \
  path "$SAVER" \
  type -int 0
defaults -currentHost write com.apple.screensaver moduleName "Omarchy Vapor"
plutil -replace moduleDict.moduleName -string "Omarchy Vapor" "$HOST_PLIST" 2>/dev/null || true
plutil -replace moduleDict.path -string "$SAVER" "$HOST_PLIST" 2>/dev/null || true

# 4) Open the Screen Saver pane so it captures a fresh preview.
open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
echo "flushed screensaver preview cache"
echo "selected $SAVER"
