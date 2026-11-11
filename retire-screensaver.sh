#!/usr/bin/env bash
# The screensavers are gone: the Ghostty idle screensaver and its idle
# watcher, the Matrix rain wallpaper and .saver, the Vapor .saver. A
# machine that ran any of them still has the launch agents loaded, the
# binaries in ~/.local/bin and the system screen saver pointed at a bundle
# this repo no longer builds. This takes all of that off and hands the
# screen saver back to macOS.
#
# install.sh and uninstall.sh both run it. Idempotent, and on a machine
# that never had the screensavers every step finds nothing to do: no
# setting is touched unless one of the pieces above was actually there.
#
#   OMACOSY_TRASH=<dir>   move files there instead of deleting them
#
# Not touched: the manual lock (Ctrl-Cmd-Q, Apple menu > Lock Screen) and
# the "require password" setting, which were never ours.
set -uo pipefail

UID_N="$(id -u)"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omacosy"
AGENTS="$HOME/Library/LaunchAgents"
BIN="$HOME/.local/bin"
SAVERS="$HOME/Library/Screen Savers"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

found=0
discard() { # path... — delete it, or park it in $OMACOSY_TRASH
  local p dest
  for p in "$@"; do
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then continue; fi
    found=1
    if [ -n "${OMACOSY_TRASH:-}" ]; then
      mkdir -p "$OMACOSY_TRASH"
      dest="$OMACOSY_TRASH/$(basename "$p")"
      if [ -e "$dest" ] || [ -L "$dest" ]; then dest="$dest.$(date +%H%M%S).$RANDOM"; fi
      mv "$p" "$dest" 2>/dev/null || rm -rf "$p"
    else
      rm -rf "$p"
    fi
  done
}

# --- 1. launch agents -------------------------------------------------------
# bootout first: every one of them is KeepAlive, so a process killed while
# its agent is still loaded comes straight back.
for label in com.omacosy.ghostty-screensaver com.omacosy.matrix-rain com.omacosy.vapor-engine; do
  if launchctl print "gui/$UID_N/$label" >/dev/null 2>&1; then
    found=1
    launchctl bootout "gui/$UID_N/$label" 2>/dev/null || true
  fi
  discard "$AGENTS/$label.plist"
done

# --- 2. processes -----------------------------------------------------------
# The idle watcher holds the display awake with its own caffeinate while a
# screensaver is up. A pid file outlives a reboot and the number gets
# reused, so the process is checked before it is signalled.
if [ -f "$STATE/ss-caffeinate.pid" ]; then
  pid="$(tr -cd '0-9' < "$STATE/ss-caffeinate.pid")"
  if [ -n "$pid" ]; then
    case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
      caffeinate | */caffeinate) kill "$pid" 2>/dev/null || true ;;
    esac
  fi
fi
pkill -f '/omacosy-screensaver-idle$' 2>/dev/null && found=1
pkill -f '/omacosy-screensaver$' 2>/dev/null && found=1
pkill -f 'ghostty-screensaver\.conf' 2>/dev/null && found=1
for name in omacosy-ss-guard omacosy-matrix-rain omacosy-vapor-engine; do
  pkill -x "$name" 2>/dev/null && found=1
done

# The Ghostty screensaver parked the system Dock's autohide delay while it
# ran and put it back on exit. Killed mid-run, the saved value is still
# here: put it back the same way.
if [ -f "$STATE/ss-dock-delay" ]; then
  v="$(tr -d '[:space:]' < "$STATE/ss-dock-delay")"
  if [ -z "$v" ] || [ "$v" = "ABSENT" ]; then
    defaults delete com.apple.dock autohide-delay >/dev/null 2>&1 || true
  else
    defaults write com.apple.dock autohide-delay -float "$v" >/dev/null 2>&1 || true
  fi
fi

# --- 3. files ---------------------------------------------------------------
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for saver in "$SAVERS/OmacosyRain.saver" "$SAVERS/OmacosyVapor.saver" "$SAVERS/OmarchyVapor.saver"; do
  [ -d "$saver" ] || continue
  "$LSREG" -u "$saver" >/dev/null 2>&1 || true
  discard "$saver"
done

discard \
  "$BIN/omacosy-screensaver" \
  "$BIN/omacosy-launch-screensaver" \
  "$BIN/omacosy-screensaver-idle" \
  "$BIN/oligarchy-screensaver-text" \
  "$BIN/omacosy-ss-guard" \
  "$BIN/omacosy-session-locked" \
  "$BIN/omacosy-matrix-rain" \
  "$BIN/omacosy-vapor-engine" \
  "$BIN/omacosy-lock"

discard \
  "$STATE/ss-idle" \
  "$STATE/ss-display-off" \
  "$STATE/ss-launched" \
  "$STATE/ss-locked-for-launch" \
  "$STATE/ss-caffeinate.pid" \
  "$STATE/ss-dock-delay" \
  "$STATE/ghostty-screensaver.conf" \
  "$STATE/matrix-rain.json" \
  "$STATE/live" \
  "$STATE/screensaver"

BRAND="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/branding"
discard "$BRAND/screensaver.txt"
rmdir "$BRAND" 2>/dev/null || true

discard \
  /tmp/omacosy-ss-idle.out \
  /tmp/omacosy-ss-idle.err \
  /tmp/omacosy-vapor-engine.err \
  /tmp/omacosy-vapor-engine.log \
  /tmp/omacosy-vapor-saver.log \
  "${TMPDIR:-/tmp}/omacosy-ss-idle.log" \
  "${TMPDIR:-/tmp}/omacosy-ss.log" \
  "$HOME/Library/Logs/omacosy-vapor-jump.log"

# --- 4. the system screen saver --------------------------------------------
# macOS's own default is "no key": the system then picks its stock module
# and its stock start delay.
#
# The module keys go only when they name one of the bundles removed above —
# a screen saver the user picked since is theirs.
DOMAIN=com.apple.screensaver
module="$(defaults -currentHost read "$DOMAIN" moduleDict 2>/dev/null || true)"
case "$module" in
  *OmacosyRain* | *OmacosyVapor* | *OmarchyVapor* | *"Omarchy Vapor"*)
    found=1
    defaults -currentHost delete "$DOMAIN" moduleDict >/dev/null 2>&1 || true
    ;;
esac
name="$(defaults -currentHost read "$DOMAIN" moduleName 2>/dev/null || true)"
case "$name" in
  OmacosyRain | OmacosyVapor | "Omarchy Vapor")
    found=1
    defaults -currentHost delete "$DOMAIN" moduleName >/dev/null 2>&1 || true
    ;;
esac

# The start delay was forced on every theme switch: 0 (never) so the
# system saver could not race the Ghostty one, 180 under Enter the Matrix.
# Those two values are indistinguishable from a choice made in System
# Settings, so they are cleared only on a run that found screensaver
# pieces to retire. A Mac that never had them keeps a "Never" its owner
# set, and so does this one on every run after the first.
if [ "$found" = 1 ]; then
  idle="$(defaults -currentHost read "$DOMAIN" idleTime 2>/dev/null || true)"
  case "$idle" in
    0 | 180) defaults -currentHost delete "$DOMAIN" idleTime >/dev/null 2>&1 || true ;;
  esac
fi
# the once-per-machine marker an earlier version of this script left
rm -f "$STATE/screensaver-retired"

if [ "$found" = 1 ]; then
  log "Retired the screensavers and their idle watcher; the screen saver is macOS's again."
fi
exit 0
