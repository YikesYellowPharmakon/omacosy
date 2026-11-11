#!/usr/bin/env bash
# Regenerate docs/screenshots/*.jpg from a STAGED laptop screen.
#
# The shots in a README are the first thing anyone sees, and the honest
# way to take them is to photograph the real thing — which is exactly
# how the old overview.jpg ended up showing the author's Spotify
# account, playlists and listening history. So this stages its own
# content: TextEdit on this repo's own markdown, on an emptied screen.
# Nothing personal is in frame because nothing personal is open.
#
# Everything on the BUILT-IN display is parked on the external one first
# (each window's origin recorded) and moved back afterwards, so the
# laptop screen is a clean slate and your session is not rearranged.
#
# usage: docs/screenshots.sh [--display N] [--keep-png]
#        --display  screencapture index to shoot; default is the built-in
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/docs/screenshots"
WORK="$(mktemp -d)"
PARK="$WORK/parked"
SHEET=/tmp/omacosy-bar-cheatsheet
A="$(command -v aerospace || echo /opt/homebrew/bin/aerospace)"
DISPLAY_N=""
KEEP_PNG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --display) DISPLAY_N="$2"; shift 2 ;;
    --keep-png) KEEP_PNG=1; shift ;;
    *) echo "usage: $0 [--display N] [--keep-png]" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }
command -v "$A" >/dev/null || die "aerospace not found"
mkdir -p "$OUT"
: > "$PARK"

# --- which screen ----------------------------------------------------------
# screencapture -D is 1-based over CGGetActiveDisplayList, so the index
# is asked of CoreGraphics rather than guessed from monitor order — they
# are not the same list, and the built-in is not reliably either end.
if [ -z "$DISPLAY_N" ]; then
  BUILTIN_INFO="$(cat <<'SWIFT' | swift - 2>/dev/null
import AppKit
var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
CGGetActiveDisplayList(8, &ids, &n)
for i in 0..<Int(n) where CGDisplayIsBuiltin(ids[i]) != 0 {
    let b = CGDisplayBounds(ids[i])
    print(i + 1, Int(b.midX), Int(b.midY)); break
}
SWIFT
)"
  DISPLAY_N="$(echo "$BUILTIN_INFO" | cut -d' ' -f1)"
  CENTRE_X="$(echo "$BUILTIN_INFO" | cut -d' ' -f2)"
  CENTRE_Y="$(echo "$BUILTIN_INFO" | cut -d' ' -f3)"
fi
[ -n "$DISPLAY_N" ] || die "could not find the built-in display; pass --display N"
say "shooting screencapture display $DISPLAY_N (built-in)"

BUILTIN_MON="$("$A" list-monitors --format '%{monitor-id}|%{monitor-name}' | grep -i "built-in" | cut -d'|' -f1)"
[ -n "$BUILTIN_MON" ] || die "aerospace does not see a built-in monitor"
OTHER_MON="$("$A" list-monitors --format '%{monitor-id}' | grep -vx "$BUILTIN_MON" | head -1 || true)"
HOME_WS="$("$A" list-workspaces --focused)"

if [ -d /Applications/Ghostty.app ]; then STAGE_APP=Ghostty; else STAGE_APP=TextEdit; fi
TEXTEDIT_WAS_RUNNING=""
pgrep -xq TextEdit && TEXTEDIT_WAS_RUNNING=1 || true
STAGED=""

restore() {
  say "restoring"
  "$HOME/.local/bin/omacosy-overview" close >/dev/null 2>&1 || true
  [ -f "$SHEET" ] && [ -n "${SHEET_OPEN:-}" ] && touch "$SHEET" || true
  # ours are identifiable by the title we launched them with, so this
  # cannot touch a terminal of yours. Killed rather than closed: a
  # close asks Ghostty, and Ghostty may answer with a modal.
  pkill -f 'ghostty --title=omacosy-shot' >/dev/null 2>&1 || true
  for wid in $(shot_window_ids 2>/dev/null); do
    "$A" close --window-id "$wid" >/dev/null 2>&1 || true
  done
  sleep 1
  if [ -n "$STAGED" ] && [ "$STAGE_APP" = TextEdit ] && [ -z "$TEXTEDIT_WAS_RUNNING" ]; then
    osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1 || true
    sleep 1
  fi
  # windows go back to the workspace they came from, one at a time, so
  # anything you opened meanwhile stays where you put it
  if [ -s "$PARK" ]; then
    say "moving $(wc -l < "$PARK" | tr -d ' ') windows back to the laptop screen"
    while IFS='	' read -r wid ws; do
      [ -n "$wid" ] && "$A" move-node-to-workspace --window-id "$wid" "$ws" >/dev/null 2>&1 || true
    done < "$PARK"
    : > /tmp/omacosy-bar-moved
  fi
  [ -n "$HOME_WS" ] && "$A" workspace "$HOME_WS" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap restore EXIT

# Every shot is checked against every EARLIER one, not just the last:
# the cheatsheet came out identical to the tiling shot two frames back
# (it had rendered on the other display) and a previous-only check said
# nothing.
grab() { # name, label
  local f="$WORK/$1.png"
  screencapture -x -o -D "$DISPLAY_N" "$f"
  local sum; sum="$(md5 -q "$f")"
  if grep -q "^$sum " "$WORK/sums" 2>/dev/null; then
    say "WARNING: $1 is identical to $(grep "^$sum " "$WORK/sums" | head -1 | cut -d' ' -f2) —"
    say "         it probably rendered on another display."
  fi
  printf '%s %s\n' "$sum" "$1" >> "$WORK/sums"
  say "captured $2"
}

# the overview and the cheatsheet both open on the display holding the
# CURSOR, and the cursor drifts as windows open — so it is put back
# before each of them rather than once at the start
# The overview and the cheatsheet open on the display holding the
# CURSOR, so the pointer has to be there — and the order matters:
# aerospace's own on-focused-monitor-changed hook runs
# `move-mouse monitor-lazy-center`, so switching workspace AFTER a warp
# drags the pointer straight back to the other display (measured:
# warped to 4196,749, and the switch put it back at 1720,720). Switch
# first, then warp. The warp emits no movement, so focus-follows-mouse
# cannot react to it either.
# our staged windows carry a title nothing else uses
shot_window_ids() {
  "$A" list-windows --all --format '%{window-id}|%{window-title}' 2>/dev/null |
    grep '|omacosy-shot$' | cut -d'|' -f1
}

aim() {
  "$A" workspace "$SCRATCH" >/dev/null 2>&1 || true
  sleep 0.4
  if [ -n "${CENTRE_X:-}" ]; then
    "$HOME/.local/bin/omacosy-helper" cursor set "$CENTRE_X" "$CENTRE_Y" 2>/dev/null || true
  fi
  sleep 0.4
}


# --- clear the laptop screen ------------------------------------------------
if [ -n "$OTHER_MON" ]; then
  say "parking the laptop screen's windows on monitor $OTHER_MON"
  "$A" list-windows --monitor "$BUILTIN_MON" --format '%{window-id}|%{workspace}' |
    while IFS='|' read -r wid ws; do
      [ -n "$wid" ] || continue
      printf '%s\t%s\n' "$wid" "$ws" >> "$PARK"
      # the twin slot on the other monitor: 13 -> 3, so groupings survive
      "$A" move-node-to-workspace --window-id "$wid" "${ws: -1}" >/dev/null 2>&1 || true
    done
  sleep 1
else
  say "single display — staging on an empty workspace instead of parking"
fi

# every empty workspace ON THE BUILT-IN: the first stages the windows,
# the rest receive them later so the overview has more than one card
EMPTY_WS=""
for ws in $("$A" list-workspaces --monitor "$BUILTIN_MON"); do
  if [ -z "$("$A" list-windows --workspace "$ws" --format '%{window-id}' 2>/dev/null)" ]; then
    EMPTY_WS="$EMPTY_WS $ws"
  fi
done
# shellcheck disable=SC2086  # unquoted on purpose: the list arrives one per line
SCRATCH="$(echo $EMPTY_WS | cut -d' ' -f1)"
[ -n "$SCRATCH" ] || die "no empty workspace on the built-in to stage in"
aim
sleep 1

# empty first: the desktop shot is the bar over the wallpaper, and it
# has to be taken BEFORE anything is staged or it is just the tiling one
grab desktop "desktop (bar over the wallpaper)"

# A tiling window manager should be shown with terminals, and a themed
# one at that: TextEdit's white windows fought the palette in every
# shot. Ghostty is the repo's default TERMINAL and opens a real window
# per invocation — which is the requirement here, and why $TERMINAL is
# not simply used: a single-window terminal (Korren keeps everything in
# one window) cannot stage a three-window layout at all.
say "staging three $STAGE_APP windows"
STAGED=1
if [ "$STAGE_APP" = Ghostty ]; then
  # Ghostty's -e is exec, NOT a shell: `cd x && cmd` came back as
  # "No such file or directory". Each window therefore runs a small
  # script file, which also sidesteps `open --args` word-splitting.
  # --confirm-close-surface=false matters at teardown: without it the
  # close raises a "Close Window?" modal and the window survives.
  term() {
    printf '#!/bin/sh\ncd "%s" || exit 1\n%s\n' "$REPO" "$2" > "$WORK/stage$1.sh"
    chmod +x "$WORK/stage$1.sh"
    open -na Ghostty --args --title="omacosy-shot" \
      --confirm-close-surface=false -e "$WORK/stage$1.sh"
  }
  term 1 'exec bat --style=numbers --paging=always README.md'; sleep 2.5
  term 2 'exec git log --graph --oneline --decorate --color=always -40 | less -R'; sleep 2.5
  term 3 'exec btop'; sleep 3
else
  open -a TextEdit "$REPO/README.md";       sleep 2
  open -a TextEdit "$REPO/ROADMAP.md";      sleep 2
  open -a TextEdit "$REPO/CONTRIBUTING.md"; sleep 3
fi

# `open -na` ACTIVATES the app, and activating pulls focus to whatever
# window of it already exists — so new windows landed on the other
# display. They are herded onto the staging workspace explicitly rather
# than hoped into place. The title is also how teardown finds them: an
# id diff raced Ghostty's window creation and leaked one every run.
if [ "$STAGE_APP" = Ghostty ]; then
  for wid in $(shot_window_ids); do
    "$A" move-node-to-workspace --window-id "$wid" "$SCRATCH" >/dev/null 2>&1 || true
  done
  aim
  # MOVED windows land as flat siblings — the split hint only shapes
  # windows at creation (ROADMAP: "re-dwindle for moved windows"), and
  # three flat columns also squeeze btop under its 80-cell minimum. So
  # the spiral is built explicitly: join the newest window (ids grow
  # with creation order) into its left neighbour's slot.
  "$A" flatten-workspace-tree >/dev/null 2>&1 || true
  sleep 0.5
  THIRD="$(shot_window_ids | sort -n | tail -1)"
  [ -n "$THIRD" ] && "$A" join-with --window-id "$THIRD" left >/dev/null 2>&1 || true
  sleep 3 # btop redraws at the tiled size, not the size it opened at
fi
grab tiling "tiling (three windows, spiral)"

say "opening the cheatsheet"
aim
touch "$SHEET"; SHEET_OPEN=1
sleep 1.5
grab cheatsheet "keybinding cheatsheet"
touch "$SHEET"; SHEET_OPEN=""
sleep 1

# One card is a poor advert for a workspace overview, so two of the
# three windows are dealt out to their own workspaces first.
say "spreading the windows across workspaces"
n=0
for wid in $("$A" list-windows --workspace "$SCRATCH" --format '%{window-id}'); do
  n=$((n + 1))
  [ "$n" -eq 1 ] && continue # one stays behind
  # shellcheck disable=SC2086  # unquoted on purpose, as above
  target="$(echo $EMPTY_WS | cut -d' ' -f$n)"
  [ -n "$target" ] && "$A" move-node-to-workspace --window-id "$wid" "$target" >/dev/null 2>&1 || true
done
: > /tmp/omacosy-bar-moved
sleep 1.5

say "opening the overview"
aim
"$HOME/.local/bin/omacosy-overview" >/dev/null 2>&1 || true
sleep 2.5
grab overview "workspace overview"
"$HOME/.local/bin/omacosy-overview" close >/dev/null 2>&1 || true
sleep 1

# JPEG at a sane width: the repo does not need retina pixels, and a
# 3024-wide PNG is megabytes of git history per shot
for f in desktop tiling overview cheatsheet; do
  [ -f "$WORK/$f.png" ] || continue
  sips -Z 1800 -s format jpeg -s formatOptions 82 \
    "$WORK/$f.png" --out "$OUT/$f.jpg" >/dev/null
  [ -n "$KEEP_PNG" ] && cp "$WORK/$f.png" "$OUT/$f.png"
  printf '    %-15s %s\n' "$f.jpg" "$(du -h "$OUT/$f.jpg" | cut -f1)"
done

say "written to docs/screenshots/ — look at them before committing:"
say "  the media pill shows whatever Spotify is playing, btop lists your"
say "  running processes, and the workspace chips show icons of apps on"
say "  your other workspaces."
