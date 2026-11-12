#!/usr/bin/env python3
"""Generate omacosy theme sidecars and apply macOS / app chrome from colors.toml."""

from __future__ import annotations

import colorsys
import json
import os
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import zlib
from pathlib import Path

PAIR = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?(#?[0-9A-Fa-f]{6})"?\s*$')
FONT = "JetBrainsMonoNL Nerd Font Mono"
FONT_FALLBACK = "JetBrainsMono Nerd Font Mono"
TYPO = Path.home() / "Library/Application Support/abnerworks.Typora/themes"
CURSOR = Path.home() / "Library/Application Support/Cursor/User/settings.json"
VSCODE = Path.home() / "Library/Application Support/Code/User/settings.json"
BTOP_CONF = Path.home() / ".config/btop/btop.conf"
BTOP_THEME = Path.home() / ".config/btop/themes/omacosy.theme"
BAT_THEME = Path.home() / ".config/bat/themes/omacosy.tmTheme"
BAT_CONF = Path.home() / ".config/bat/config"
LAZYGIT = Path.home() / ".config/lazygit/config.yml"
DELTA_GIT = Path.home() / ".config/omacosy/delta.gitconfig"
GITCONFIG = Path.home() / ".gitconfig"
COLOR_DIR = Path.home() / ".local/state/omacosy/color"

APPLE_HEX = {
    -1: "#98989d",
    0: "#ff3b30",
    1: "#ff9500",
    2: "#ffcc00",
    3: "#34c759",
    4: "#007aff",
    5: "#af52de",
    6: "#ff2d55",
}

PRESETS = {
    -1: (152, 152, 157),
    0: (255, 59, 48),
    1: (255, 149, 0),
    2: (255, 204, 0),
    3: (52, 199, 76),
    4: (0, 122, 255),
    5: (175, 82, 222),
    6: (255, 45, 85),
}

# These themes' own accents are gray-blue or cyan. The candidate bar
# paints AppleHighlightColor, so the raw accent reads as gray. Pin the
# input highlight to system blue; borders still use the theme accent.
IME_BLUE_THEMES = {"azure"}


def parse_colors(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.is_file():
        return data
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = PAIR.match(stripped)
        if match:
            val = match.group(2)
            data[match.group(1)] = val if val.startswith("#") else f"#{val}"
    return data


def hex_to_rgb(value: str) -> tuple[int, int, int]:
    value = value.strip().lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def luminance(value: str) -> float:
    r, g, b = hex_to_rgb(value)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255


def color_distance(a: str, b: str) -> float:
    ra, ga, ba = hex_to_rgb(a)
    rb, gb, bb = hex_to_rgb(b)
    return ((ra - rb) ** 2 + (ga - gb) ** 2 + (ba - bb) ** 2) ** 0.5


def rgb_ansi(hex_color: str) -> str:
    r, g, b = hex_to_rgb(hex_color)
    return f"38;2;{r};{g};{b}"


def text_on(bg: str, colors: dict[str, str]) -> str:
    dark = colors["background"] if luminance(colors["background"]) < 0.5 else "#121212"
    light = colors["foreground"] if luminance(colors["foreground"]) > 0.45 else "#f5f5f5"
    chosen = dark if luminance(bg) > 0.48 else light
    if abs(luminance(bg) - luminance(chosen)) < 0.28:
        chosen = "#121212" if luminance(bg) > 0.48 else "#f5f5f5"
    return chosen


def argb(hex_color: str, alpha: str = "ff") -> str:
    return f"0x{alpha}{hex_color.lstrip('#').lower()}"


def replace_file(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or path.exists():
        path.unlink()
    path.write_text(text, encoding="utf-8")


def vivid_slots(colors: dict[str, str]) -> list[int]:
    ink = ansi_palette(colors)
    return sorted(range(1, 7), key=lambda slot: _hsv_of(ink[slot])[1], reverse=True)


def _chromatic_options(colors: dict[str, str]) -> list[str]:
    found: list[str] = []
    for key in (
        "red",
        "orange",
        "yellow",
        "green",
        "cyan",
        "blue",
        "magenta",
        "color1",
        "color2",
        "color3",
        "color4",
        "color5",
        "color6",
    ):
        raw = colors.get(key)
        if not raw:
            continue
        _hue, sat, val = _hsv_of(raw)
        if sat < 0.22 or val < 0.2:
            continue
        if any(color_distance(raw, prev) < 28 for prev in found):
            continue
        found.append(raw)
    return found


def _closest_hue(
    options: list[str], target: float, used: list[str], window: float | None = None
) -> str | None:
    best: str | None = None
    best_d = 9.0
    for color in options:
        if any(color_distance(color, prev) < 36 for prev in used):
            continue
        dist = _hue_dist(_hsv_of(color)[0], target)
        if window is not None and dist > window:
            continue
        if dist < best_d:
            best, best_d = color, dist
    return best


def ribbon_colors(colors: dict[str, str]) -> dict[str, tuple[str, str]]:
    """Solid theme colors for one connected powerline ribbon.

    Matrix leads with its green. Other themes lead with their warm color,
    then yellow, green, and blue — the same run as the Gruvbox ribbon.
    Fills stay the theme's own hex; they are not mixed into the background.
    """
    options = _chromatic_options(colors)
    face = theme_face(colors)
    face_h = _hsv_of(face)[0]
    used: list[str] = []
    theme = colors.get("_theme_name", "")
    if theme == "snow-black":
        # Upstream snow_black leads with its pink, not a gray.
        user = colors.get("color2") or "#DD9999"
    elif 0.18 <= face_h <= 0.48:
        user = face
    else:
        user = _closest_hue(options, 0.04, [], window=0.12) or face
    used.append(user)

    def take(color: str) -> str:
        if all(color_distance(color, prev) >= 36 for prev in used):
            used.append(color)
            return color
        hue, sat, val = _hsv_of(used[-1])
        if not _hue_blocked(theme, hue):
            for delta in (0.18, -0.16, 0.30, -0.26):
                alt = _from_hsv(hue, min(0.8, max(sat, 0.28)), min(0.92, max(0.34, val + delta)))
                if all(color_distance(alt, prev) >= 36 for prev in used):
                    used.append(alt)
                    return alt
        used.append(color)
        return color

    # Matrix stays in its greens. Space Monkey stays warm.
    # Snow's ribbon stays in blue-green and gray.
    if theme == "enter-the-matrix":
        git_hue, lang_hue = 0.28, 0.38
    elif theme == "space-monkey":
        git_hue, lang_hue = 0.97, 0.07
    else:
        git_hue, lang_hue = 0.33, 0.56
    if theme == "snow-black":
        # Rose, teal, then the gray accent. Same slots as colors.toml.
        directory = colors.get("color3") or user
        git = colors.get("color1") or directory
        lang = colors.get("color4") or git
        used.extend((directory, git, lang))
    else:
        directory = take(_closest_hue(options, 0.14, used) or user)
        git = take(_closest_hue(options, git_hue, used) or directory)
        lang = take(_closest_hue(options, lang_hue, used) or git)

    bg, fg = colors["background"], colors["foreground"]
    muted = colors.get("color8") or colors.get("muted") or ""
    if muted and color_distance(muted, bg) >= 40 and abs(luminance(muted) - luminance(bg)) >= 0.16:
        extra = muted
    else:
        extra = mix_hex(bg, fg, 0.46)

    def pair(body: str) -> tuple[str, str]:
        return body, text_on(body, colors)

    return {
        "user": pair(user),
        "dir": pair(directory),
        "git": pair(git),
        "lang": pair(lang),
        "extra": pair(extra),
    }


def render_starship(colors: dict[str, str]) -> str:
    """Connected powerline: apple + user, directory, git, then a new line.

    Arrows sit in the top-level format, so a missing git or node segment
    collapses into the small chevron at the end instead of a gap. Language
    and docker text use the theme's own colors and only appear when that
    tool is actually here. A nested zsh adds a Z on the last segment.
    """
    ribbon = ribbon_colors(colors)
    user, user_fg = ribbon["user"]
    directory, dir_fg = ribbon["dir"]
    git, git_fg = ribbon["git"]
    lang, lang_fg = ribbon["lang"]
    extra, extra_fg = ribbon["extra"]
    prompt = colors["foreground"]
    error = colors.get("red") or colors["color1"]
    left, arrow = "\ue0b6", "\ue0b0"
    parts = [
        f"[{left}](fg:{user})",
        "$os",
        "$username",
        f"[{arrow}](fg:{user} bg:{directory})",
        "$directory",
        f"[{arrow}](fg:{directory} bg:{git})",
        "$git_branch",
        "$git_status",
        f"[{arrow}](fg:{git} bg:{lang})",
        "$nodejs",
        "$python",
        "$rust",
        "$golang",
        "$ruby",
        "$php",
        "$java",
        "$bun",
        f"[{arrow}](fg:{lang} bg:{extra})",
        "$docker_context",
        "$custom",
        f"[{arrow}](fg:{extra})",
        "$line_break$character",
    ]
    body = "\\\n".join(parts)
    langs = (
        ("nodejs", "\ue718"),
        ("python", "\ue606"),
        ("rust", "\ue7a8"),
        ("golang", "\ue627"),
        ("ruby", "\ue791"),
        ("php", "\ue608"),
        ("java", "\ue256"),
        ("bun", "\ue76f"),
    )
    lang_toml = "\n".join(
        f"[{name}]\n"
        f'symbol = "{symbol}"\n'
        f'style = "bg:{lang}"\n'
        f"format = '[[ $symbol $version ](fg:{lang_fg} bg:{lang})]($style)'\n"
        for name, symbol in langs
    )
    return (
        "# generated by theme-pack from the active omacosy theme\n"
        "format = \"\"\"\n"
        f"{body}\"\"\"\n"
        "\n"
        "add_newline = false\n"
        "\n"
        "[os]\n"
        "disabled = false\n"
        f'style = "bg:{user} fg:{user_fg}"\n'
        'format = "[$symbol]($style)"\n'
        "\n"
        "[os.symbols]\n"
        'Macos = "\uf179"\n'
        "\n"
        "[username]\n"
        "show_always = true\n"
        f'style_user = "bg:{user} fg:{user_fg} bold"\n'
        f'style_root = "bg:{user} fg:{user_fg} bold"\n'
        'format = "[ $user ]($style)"\n'
        "\n"
        "[directory]\n"
        f'style = "fg:{dir_fg} bg:{directory} bold"\n'
        'format = "[ \uf07b $path ]($style)"\n'
        "truncation_length = 3\n"
        'truncation_symbol = "…/"\n'
        "\n"
        "[git_branch]\n"
        'symbol = "\uf418"\n'
        f'style = "bg:{git}"\n'
        f"format = '[[ $symbol $branch ](fg:{git_fg} bg:{git})]($style)'\n"
        "\n"
        "[git_status]\n"
        f'style = "bg:{git}"\n'
        f"format = '[[($all_status$ahead_behind )](fg:{git_fg} bg:{git})]($style)'\n"
        "\n"
        f"{lang_toml}\n"
        "[docker_context]\n"
        'symbol = "\uf308"\n'
        f'style = "bg:{extra}"\n'
        f"format = '[[ $symbol $context ](fg:{extra_fg} bg:{extra})]($style)'\n"
        "\n"
        "[custom.shellmark]\n"
        'when = "test \\"${SHLVL:-1}\\" -gt 2"\n'
        'command = "printf Z"\n'
        f'style = "bg:{extra} fg:{extra_fg} bold"\n'
        'format = "[ $output ]($style)"\n'
        "\n"
        "[line_break]\n"
        "disabled = false\n"
        "\n"
        "[character]\n"
        f'success_symbol = "[>](fg:{prompt} bold)"\n'
        f'error_symbol = "[>](fg:{error} bold)"\n'
        f'vimcmd_symbol = "[>](fg:{prompt} bold)"\n'
        f'vimcmd_replace_one_symbol = "[>](fg:{error} bold)"\n'
        f'vimcmd_replace_symbol = "[>](fg:{error} bold)"\n'
        f'vimcmd_visual_symbol = "[>](fg:{directory} bold)"\n'
    )


def nearest_apple_accent(hex_color: str) -> int:
    r, g, b = hex_to_rgb(hex_color)
    h, s, _ = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    if s < 0.18:
        return -1
    hues = {0: 0.00, 6: 0.96, 1: 0.08, 2: 0.13, 3: 0.33, 4: 0.59, 5: 0.78}

    def dist(key: int) -> float:
        dh = abs(h - hues[key])
        return min(dh, 1 - dh)

    return min(hues, key=dist)


def _hue_blocked(theme: str, hue: float) -> bool:
    """Hues this theme's staining is not allowed to use."""
    if theme == "enter-the-matrix":
        # Blue, and the red that sits outside the green theme.
        if 0.46 <= hue <= 0.78:
            return True
        if hue <= 0.06 or hue >= 0.90:
            return True
        return False
    if theme == "space-monkey":
        return 0.40 <= hue <= 0.84
    if theme == "snow-black":
        # Sky blue. The cool grays and the teal stay.
        return 0.55 <= hue <= 0.80
    return False


def restyle_theme(colors: dict[str, str], theme: str) -> dict[str, str]:
    """Move blocked hues onto the rest of the theme before anything is painted.

    Matrix has no blue and no red. Space Monkey has no teal, blue, or periwinkle.
    The same hex always moves to the same replacement, so a normal color
    and its bright copy stay a pair.
    """
    colors["_theme_name"] = theme
    if theme not in {"enter-the-matrix", "space-monkey"}:
        return colors
    keys = (
        "red",
        "orange",
        "yellow",
        "green",
        "cyan",
        "blue",
        "magenta",
        "accent",
        "bright_red",
        "bright_yellow",
        "bright_green",
        "bright_cyan",
        "bright_blue",
        "bright_magenta",
        "color1",
        "color2",
        "color3",
        "color4",
        "color5",
        "color6",
        "color9",
        "color10",
        "color11",
        "color12",
        "color13",
        "color14",
        "_theme_accent",
    )
    # Matrix replacements stay in the green. Space Monkey replacements stay warm.
    # Neither set sits on the theme's own yellow, or the new color steals that role.
    landings = (0.32, 0.38, 0.27) if theme == "enter-the-matrix" else (0.03, 0.97, 0.08)
    kept: list[str] = []
    pending: list[str] = []
    for key in keys:
        value = colors.get(key)
        if not value or not str(value).startswith("#"):
            continue
        hue, sat, _val = _hsv_of(value)
        if sat >= 0.18 and _hue_blocked(theme, hue):
            pending.append(key)
        elif sat >= 0.18:
            kept.append(value)
    cache: dict[str, str] = {}
    used = list(kept)
    for key in pending:
        raw = colors[key]
        token = raw.lower()
        if token in cache:
            colors[key] = cache[token]
            continue
        _hue, sat, val = _hsv_of(raw)
        best = raw
        best_score = -1.0
        # Matrix replacements stay with the other greens, not a neon.
        hi = 0.72 if theme == "enter-the-matrix" else 0.92
        for hue in landings:
            for delta in (0.0, 0.1, -0.08):
                cand = _from_hsv(
                    hue,
                    min(0.82, max(sat, 0.5)),
                    min(hi, max(0.38, val + delta)),
                )
                score = min((color_distance(cand, other) for other in used), default=999.0)
                if score > best_score:
                    best, best_score = cand, score
        cache[token] = best
        used.append(best)
        colors[key] = best
    return colors


def _surface_colors(colors: dict[str, str]) -> list[str]:
    """Colors for meters, listings, and chrome."""
    ink = ansi_palette(colors)
    return [ink[2], ink[3], ink[1], ink[4], ink[6], ink[5]]


def normalize(colors: dict[str, str]) -> dict[str, str]:
    if "background" not in colors:
        raise ValueError("colors.toml missing background")
    colors.setdefault("foreground", colors.get("bright_foreground", "#c0caf5"))
    colors.setdefault("accent", colors.get("blue", colors.get("color4", colors["foreground"])))
    colors.setdefault("cursor", colors.get("bright_foreground", colors["foreground"]))
    colors.setdefault(
        "selection_background",
        colors.get("selection", colors.get("lighter_background", colors.get("color8", colors["background"]))),
    )
    colors.setdefault("selection_foreground", colors.get("bright_foreground", colors["foreground"]))
    named = {
        0: colors.get("darker_background", colors["background"]),
        1: colors.get("red", colors.get("color1", "#f7768e")),
        2: colors.get("green", colors.get("color2", "#9ece6a")),
        3: colors.get("yellow", colors.get("color3", "#e0af68")),
        4: colors.get("blue", colors.get("color4", colors["accent"])),
        5: colors.get("magenta", colors.get("color5", "#bb9af7")),
        6: colors.get("cyan", colors.get("color6", "#7dcfff")),
        7: colors.get("foreground"),
        8: colors.get("muted", colors.get("dark_foreground", colors.get("color8", "#555555"))),
        9: colors.get("bright_red", colors.get("color9", colors.get("red", "#f7768e"))),
        10: colors.get("bright_green", colors.get("color10", colors.get("green", "#9ece6a"))),
        11: colors.get("bright_yellow", colors.get("color11", colors.get("yellow", "#e0af68"))),
        12: colors.get("bright_blue", colors.get("color12", colors.get("blue", colors["accent"]))),
        13: colors.get("bright_magenta", colors.get("color13", colors.get("magenta", "#bb9af7"))),
        14: colors.get("bright_cyan", colors.get("color14", colors.get("cyan", "#7dcfff"))),
        15: colors.get("bright_foreground", colors.get("color15", colors["foreground"])),
    }
    for i, value in named.items():
        colors.setdefault(f"color{i}", value)
    colors.setdefault("muted", colors.get("color8", colors["foreground"]))
    return colors


def mix_hex(a: str, b: str, t: float) -> str:
    ar, ag, ab = hex_to_rgb(a)
    br, bg, bb = hex_to_rgb(b)
    r = int(ar * (1 - t) + br * t)
    g = int(ag * (1 - t) + bg * t)
    bl = int(ab * (1 - t) + bb * t)
    return f"#{r:02x}{g:02x}{bl:02x}"


def _hsv_of(color: str) -> tuple[float, float, float]:
    r, g, b = hex_to_rgb(color)
    return colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)


def _from_hsv(h: float, s: float, v: float) -> str:
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, max(0.0, min(1.0, s)), max(0.0, min(1.0, v)))
    return f"#{round(r * 255):02x}{round(g * 255):02x}{round(b * 255):02x}"


def punch_on(color: str, surface: str) -> str:
    """Keep the hue, but pull it far enough off the surface to read.

    Gray stays gray. A chromatic theme color gets enough saturation and
    lightness that it does not collapse into the background.
    """
    h, s, v = _hsv_of(color)
    dark = luminance(surface) < 0.5
    # Already readable against the surface: keep the hex, pale pastels
    # included. Recoloring those is what pulled themes off their own colors.
    if abs(luminance(color) - luminance(surface)) >= 0.15 or color_distance(color, surface) >= 70:
        return color
    if s < 0.14:
        v = max(v, 0.58) if dark else min(v, 0.36)
        return _from_hsv(h, s, v)
    s = min(0.84, max(s, 0.5))
    v = min(0.9, max(v, 0.58)) if dark else max(0.22, min(v, 0.46))
    out = _from_hsv(h, s, v)
    if abs(luminance(out) - luminance(surface)) < 0.2:
        out = _from_hsv(h, s, 0.76 if dark else 0.28)
    return out


def comment_ink(colors: dict[str, str]) -> str:
    """Dimmer than code, still readable on the theme background."""
    h, s, _v = _hsv_of(colors["muted"])
    dark = luminance(colors["background"]) < 0.5
    if s < 0.14:
        return _from_hsv(h, s, 0.48 if dark else 0.38)
    return _from_hsv(h, min(0.55, max(s, 0.28)), 0.52 if dark else 0.36)


def contrasting_bg(text: str, preferred: str) -> str:
    """A bar color apps can paint under text they refuse to recolor."""
    if abs(luminance(preferred) - luminance(text)) >= 0.45:
        return preferred
    target = "#101010" if luminance(text) > 0.55 else "#f3f3f3"
    chosen = preferred
    for step in (0.35, 0.55, 0.75, 0.9, 1.0):
        chosen = mix_hex(preferred, target, step)
        if abs(luminance(chosen) - luminance(text)) >= 0.45:
            return chosen
    return chosen


def _hue_dist(a: float, b: float) -> float:
    span = abs(a - b)
    return min(span, 1.0 - span)


def chromatic_family(colors: dict[str, str]) -> list[tuple[float, float]]:
    """Hues the theme already uses, strongest first.

    Gray slots borrow from this family instead of staying identical.
    """
    found: list[tuple[float, float]] = []
    keys = [f"color{i}" for i in range(1, 15)] + ["accent"]
    for key in keys:
        value = colors.get(key)
        if not value:
            continue
        hue, sat, val = _hsv_of(value)
        if sat < 0.16 or val < 0.12:
            continue
        if any(_hue_dist(hue, other) < 0.05 for other, _sat in found):
            continue
        found.append((hue, sat))
    found.sort(key=lambda item: item[1], reverse=True)
    return found


def enrich_ansi(colors: dict[str, str], ink: list[str]) -> list[str]:
    """Give colliding or gray ANSI slots their own step in the theme's hues.

    A slot that is already its own color is left alone.
    """
    if colors.get("_theme_name") == "snow-black":
        # The gray slots are the lace. Borrowing the teal walks them into
        # pale blue, which fights the wallpaper.
        return ink
    family = chromatic_family(colors)
    if not family:
        return ink
    dark = luminance(colors["background"]) < 0.5
    out = list(ink)
    placed: list[str] = []
    for index, slot in enumerate((1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14)):
        _hue, sat, _val = _hsv_of(out[slot])
        # Only gray slots borrow a hue. A chromatic slot is the theme's
        # own choice, even when two of them sit close (Matrix cyan and green).
        if sat < 0.18:
            base_hue, base_sat = family[index % len(family)]
            used = sum(1 for prev in placed if _hue_dist(_hsv_of(prev)[0], base_hue) < 0.08)
            hue = (base_hue + min(0.10, used * 0.04)) % 1.0
            if dark:
                val = (0.58 if slot < 8 else 0.74) + (used % 4) * 0.08
            else:
                val = (0.42 if slot < 8 else 0.32) - (used % 3) * 0.05
            out[slot] = _from_hsv(hue, min(0.84, max(base_sat, 0.5)), max(0.26, min(0.94, val)))
        placed.append(out[slot])
    return out


def ansi_palette(colors: dict[str, str]) -> list[str]:
    """The 16 colors the theme wrote down.

    A slot changes only when it would vanish into the background, or when
    a gray slot borrows one of the theme's hues. Monokai pink and Matrix
    green stay the hex in colors.toml, including the bright row when the
    theme made those the same color.
    """
    bg = colors["background"]
    out: list[str] = []
    for i in range(16):
        raw = colors[f"color{i}"]
        if i in (7, 15):
            out.append(raw)
        elif i in (0, 8) and color_distance(raw, bg) < 18:
            out.append(mix_hex(bg, colors["foreground"], 0.16 if i == 0 else 0.34))
        elif i in (0, 8):
            out.append(raw)
        else:
            out.append(punch_on(raw, bg))
    return separate_slots(enrich_ansi(colors, out), colors)


def separate_slots(ink: list[str], colors: dict[str, str] | None = None) -> list[str]:
    """Split slots that still match, without leaving the theme's hue.

    A bright color the theme set equal to its normal color stays equal.
    """
    pairs = {9: 1, 10: 2, 11: 3, 12: 4, 13: 5, 14: 6}
    out = list(ink)
    placed: list[str] = []
    for slot in (1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14):
        if colors and slot in pairs:
            base = colors.get(f"color{pairs[slot]}", "")
            bright = colors.get(f"color{slot}", "")
            if base.lower() == bright.lower():
                placed.append(out[slot])
                continue
        hue, sat, val = _hsv_of(out[slot])
        color = out[slot]
        for step in range(7):
            light = min(0.96, max(0.34, val + step * 0.08))
            candidate = color if step == 0 else _from_hsv(hue, sat, light)
            if all(color_distance(candidate, prev) >= 28 for prev in placed):
                color = candidate
                break
        out[slot] = color
        placed.append(color)
    return out


def theme_face(colors: dict[str, str]) -> str:
    """The color a theme is recognized by: its accent, not the loudest ANSI slot.

    Matrix defines a red, but the theme is the green. Wallpaper mixing
    stores the original accent on `_theme_accent` so Ghostty does not
    inherit the desktop sample.
    """
    raw = colors.get("_theme_accent") or colors["accent"]
    if _hsv_of(raw)[1] >= 0.18 and abs(luminance(raw) - luminance(colors["background"])) >= 0.16:
        return raw
    return signature_ink(colors)


def signature_ink(colors: dict[str, str]) -> str:
    """The username badge uses a color the theme actually defined."""
    found: list[str] = []
    for key in ("color1", "color2", "color3", "color4", "color5", "color6", "accent"):
        raw = colors.get(key)
        if not raw or _hsv_of(raw)[1] < 0.16:
            continue
        punched = punch_on(raw, colors["background"])
        if all(color_distance(punched, prev) >= 28 for prev in found):
            found.append(punched)
    if not found:
        return ansi_palette(colors)[vivid_slots(colors)[0]]
    return max(found, key=lambda item: _hsv_of(item)[1])


def _cube_cell(bg: str, red: str, green: str, blue: str, r: float, g: float, b: float) -> str:
    """Keep the winning hue. Averaging teal with rose just makes gray."""
    ranked = sorted(((r, red), (g, green), (b, blue)), key=lambda item: item[0], reverse=True)
    if ranked[0][0] <= 0:
        return bg
    mixed = ranked[0][1]
    if ranked[1][0] > 0:
        mixed = mix_hex(mixed, ranked[1][1], 0.22 * ranked[1][0])
    return mix_hex(bg, mixed, max(r, g, b))


def palette_256(colors: dict[str, str]) -> list[str]:
    """ANSI slots plus a cube and gray ramp built from this theme.

    Ghostty otherwise keeps the stock xterm cube, so anything using
    256 colors ignores the theme.
    """
    ansi = ansi_palette(colors)
    steps = (0.0, 0.2, 0.38, 0.56, 0.76, 1.0)
    red, green, blue = ansi[1], ansi[2], ansi[4]
    bg, fg = colors["background"], colors["foreground"]
    cube = [
        _cube_cell(bg, red, green, blue, r, g, b)
        for r in steps
        for g in steps
        for b in steps
    ]
    ramp = [mix_hex(bg, fg, i / 23) for i in range(24)]
    palette = ansi + cube + ramp
    if len(palette) != 256:
        raise RuntimeError(f"palette length {len(palette)}")
    return palette


def syntax_inks(colors: dict[str, str]) -> dict[str, str]:
    ansi = ansi_palette(colors)
    found = {
        "comment": comment_ink(colors),
        "string": ansi[2],
        "regexp": ansi[1],
        "escape": ansi[9],
        "number": ansi[3],
        "keyword": ansi[1],
        "storage": ansi[5],
        "operator": ansi[5],
        "function": ansi[4],
        "method": ansi[12],
        "type": ansi[3],
        "class": ansi[11],
        "namespace": ansi[6],
        "variable": colors["foreground"],
        "parameter": ansi[13],
        "property": ansi[6],
        "constant": ansi[5],
        "tag": ansi[1],
        "attribute": ansi[3],
        "heading": punch_on(colors["accent"], colors["background"]),
        "link": ansi[4],
        "inserted": ansi[2],
        "deleted": ansi[1],
        "changed": ansi[3],
        "invalid": ansi[9],
        "decorator": ansi[5],
        "punctuation": comment_ink(colors),
    }
    return found


# scope, ink key, optional fontStyle. Every theme reuses this table.
SYNTAX_SCOPES: tuple[tuple[str, str, str], ...] = (
    ("comment", "comment", "italic"),
    ("comment.line", "comment", "italic"),
    ("comment.block", "comment", "italic"),
    ("comment.block.documentation", "namespace", "italic"),
    ("comment.block.docstring", "namespace", "italic"),
    ("punctuation.definition.comment", "comment", ""),
    ("string", "string", ""),
    ("string.quoted", "string", ""),
    ("string.template", "string", ""),
    ("string.interpolated", "escape", ""),
    ("string.regexp", "regexp", ""),
    ("constant.character.escape", "escape", ""),
    ("punctuation.definition.string", "string", ""),
    ("constant.numeric", "number", ""),
    ("constant.language", "number", ""),
    ("constant.character", "number", ""),
    ("constant.other", "constant", ""),
    ("constant.other.symbol", "constant", ""),
    ("constant.other.placeholder", "changed", ""),
    ("keyword", "keyword", ""),
    ("keyword.control", "keyword", ""),
    ("keyword.control.import", "storage", ""),
    ("keyword.control.from", "storage", ""),
    ("keyword.operator", "operator", ""),
    ("keyword.other", "storage", ""),
    ("keyword.other.unit", "number", ""),
    ("storage", "storage", ""),
    ("storage.type", "type", ""),
    ("storage.modifier", "storage", ""),
    ("storage.type.class", "class", ""),
    ("storage.type.function", "function", ""),
    ("entity.name.function", "function", ""),
    ("entity.name.function.method", "method", ""),
    ("support.function", "function", ""),
    ("support.function.builtin", "method", ""),
    ("meta.function-call", "function", ""),
    ("variable.function", "function", ""),
    ("entity.name.class", "class", ""),
    ("entity.name.type", "type", ""),
    ("entity.name.namespace", "namespace", ""),
    ("entity.other.inherited-class", "class", ""),
    ("support.class", "class", ""),
    ("support.type", "type", ""),
    ("support.constant", "constant", ""),
    ("variable", "variable", ""),
    ("variable.other", "variable", ""),
    ("variable.parameter", "parameter", ""),
    ("variable.language", "constant", ""),
    ("variable.other.member", "property", ""),
    ("variable.other.property", "property", ""),
    ("variable.other.constant", "constant", ""),
    ("variable.annotation", "decorator", ""),
    ("entity.name.tag", "tag", ""),
    ("punctuation.definition.tag", "tag", ""),
    ("entity.other.attribute-name", "attribute", ""),
    ("entity.other.attribute-name.id", "function", ""),
    ("entity.other.attribute-name.class", "type", ""),
    ("support.type.property-name", "property", ""),
    ("meta.object-literal.key", "property", ""),
    ("meta.mapping.key", "property", ""),
    ("entity.name.section", "heading", "bold"),
    ("markup.heading", "heading", "bold"),
    ("markup.heading.1", "heading", "bold"),
    ("markup.heading.2", "function", "bold"),
    ("markup.heading.3", "type", "bold"),
    ("punctuation.definition.heading", "heading", ""),
    ("markup.bold", "variable", "bold"),
    ("markup.italic", "namespace", "italic"),
    ("markup.raw", "string", ""),
    ("markup.inline.raw", "string", ""),
    ("markup.quote", "comment", "italic"),
    ("markup.list", "heading", ""),
    ("markup.underline.link", "link", "underline"),
    ("string.other.link", "link", "underline"),
    ("markup.inserted", "inserted", ""),
    ("markup.deleted", "deleted", ""),
    ("markup.changed", "changed", ""),
    ("punctuation", "punctuation", ""),
    ("punctuation.definition", "punctuation", ""),
    ("punctuation.separator", "punctuation", ""),
    ("punctuation.terminator", "punctuation", ""),
    ("meta.brace", "punctuation", ""),
    ("invalid", "invalid", ""),
    ("invalid.deprecated", "comment", "italic"),
    ("entity.name.decorator", "decorator", ""),
    ("meta.decorator", "decorator", ""),
    ("keyword.other.special-method", "method", ""),
    ("support.type.vendored", "namespace", ""),
    ("token.info-token", "function", ""),
    ("token.warn-token", "changed", ""),
    ("token.error-token", "deleted", ""),
    ("token.debug-token", "comment", ""),
)


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    return min((a, b, c), key=lambda x: abs(p - x))


def read_png_pixels(path: Path) -> list[tuple[int, int, int]]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return []
    pos = 8
    width = height = 0
    color = 2
    raw = b""
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        typ = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if typ == b"IHDR":
            width, height, _bit, color = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            raw += chunk
        elif typ == b"IEND":
            break
    if not width or not raw:
        return []
    rows = zlib.decompress(raw)
    bpp = {2: 3, 6: 4, 0: 1}.get(color, 3)
    stride = 1 + width * bpp
    pixels: list[tuple[int, int, int]] = []
    prev = bytearray(width * bpp)
    for y in range(height):
        start = y * stride
        if start + stride > len(rows):
            break
        filt = rows[start]
        scan = bytearray(rows[start + 1 : start + stride])
        for i, value in enumerate(scan):
            left = scan[i - bpp] if i >= bpp else 0
            up = prev[i]
            ul = prev[i - bpp] if i >= bpp else 0
            if filt == 1:
                scan[i] = (value + left) & 255
            elif filt == 2:
                scan[i] = (value + up) & 255
            elif filt == 3:
                scan[i] = (value + ((left + up) // 2)) & 255
            elif filt == 4:
                scan[i] = (value + _paeth(left, up, ul)) & 255
        prev = scan
        for x in range(width):
            i = x * bpp
            if bpp == 1:
                pixels.append((scan[i], scan[i], scan[i]))
            else:
                pixels.append((scan[i], scan[i + 1], scan[i + 2]))
    return pixels


def sample_wallpaper(path: Path) -> tuple[str | None, str | None, float | None]:
    tmp = Path("/tmp/omacosy-wall-sample.png")
    try:
        subprocess.run(
            ["sips", "-s", "format", "png", "-z", "24", "24", str(path), "--out", str(tmp)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return None, None, None
    pixels = read_png_pixels(tmp)
    if tmp.exists():
        tmp.unlink()
    if not pixels:
        return None, None, None
    n = len(pixels)
    ar = sum(p[0] for p in pixels) / n
    ag = sum(p[1] for p in pixels) / n
    ab = sum(p[2] for p in pixels) / n
    avg = f"#{int(ar):02x}{int(ag):02x}{int(ab):02x}"
    best = None
    best_s = -1.0
    for r, g, b in pixels:
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if 0.18 < v < 0.92 and s > best_s:
            best_s = s
            best = (r, g, b)
    vibrant = f"#{best[0]:02x}{best[1]:02x}{best[2]:02x}" if best else avg
    lum = (0.2126 * ar + 0.7152 * ag + 0.0722 * ab) / 255
    return avg, vibrant, lum


def adapt_colors(colors: dict[str, str], wallpaper: Path | None) -> dict[str, str]:
    adapted = dict(colors)
    if wallpaper is None or not wallpaper.is_file():
        return adapted
    avg, vibrant, lum = sample_wallpaper(wallpaper)
    if not avg or not vibrant:
        return adapted
    adapted["_theme_accent"] = colors["accent"]
    adapted["_theme_selection"] = colors.get("selection_background", colors["accent"])
    adapted["accent"] = mix_hex(colors["accent"], vibrant, 0.42)
    adapted["selection_background"] = mix_hex(colors["selection_background"], avg, 0.28)
    if lum is not None:
        if lum >= 0.62:
            adapted["_wallpaper_light"] = "1"
        elif lum <= 0.38:
            adapted["_wallpaper_light"] = "0"
    adapted["_wallpaper_avg"] = avg
    return adapted


def color_file(theme_dir: Path) -> Path:
    return COLOR_DIR / theme_dir.name


def load_color_mode(theme_dir: Path) -> str:
    path = color_file(theme_dir)
    if path.is_file():
        return path.read_text(encoding="utf-8").strip() or "theme"
    return "theme"


def save_color_mode(theme_dir: Path, mode: str) -> None:
    COLOR_DIR.mkdir(parents=True, exist_ok=True)
    color_file(theme_dir).write_text(mode.strip() + "\n", encoding="utf-8")


def apply_color_mode(colors: dict[str, str], wallpaper: Path | None, mode: str) -> dict[str, str]:
    mode = (mode or "theme").strip()
    out = dict(colors)
    if mode == "wallpaper":
        return adapt_colors(out, wallpaper)
    if mode.startswith("apple:"):
        try:
            apple = int(mode.split(":", 1)[1])
        except ValueError:
            return out
        hexv = APPLE_HEX.get(apple)
        if hexv:
            out["accent"] = hexv
            out["_apple_accent"] = str(apple)
        return out
    if mode.startswith("palette:"):
        key = mode.split(":", 1)[1]
        if key in out:
            out["accent"] = out[key]
        return out
    if mode.startswith("hex:"):
        value = mode.split(":", 1)[1]
        if value.startswith("#") and len(value) == 7:
            out["accent"] = value
        return out
    return out


def bar_item_bg(colors: dict[str, str]) -> str:
    """Fill behind the bar's icon pills.

    The old fill was color8. On Space Monkey that is a light gray, which
    sits on the rust-and-brown theme like a sticker. Build the pill from
    the theme background plus a little accent instead. A light wallpaper
    shows through the clear bar, so Snow's near-black pill becomes a
    hole; lift that one toward the wallpaper, and stop while white
    labels on the pill still read.
    """
    bg = colors["background"]
    accent = _chrome_accent(colors)
    pill = mix_hex(bg, accent, 0.32)
    if color_distance(pill, bg) < 20:
        pill = mix_hex(bg, colors["foreground"], 0.14)
    wall = colors.get("_wallpaper_avg")
    if colors.get("_wallpaper_light") == "1" and wall:
        lifted = pill
        # Snow's lace wallpaper is bright. A slightly higher cap keeps the
        # pills readable and a step lighter than the first lift.
        cap = 0.56 if colors.get("_theme_name") == "snow-black" else 0.44
        for step in (0.28, 0.40, 0.52, 0.64, 0.74):
            candidate = mix_hex(pill, wall, step)
            if luminance(candidate) > cap:
                break
            lifted = candidate
        pill = lifted
    return pill


def _is_current_theme(theme_dir: Path) -> bool:
    link = Path.home() / ".config/omarchy/current/theme"
    try:
        return link.resolve() == theme_dir.resolve()
    except OSError:
        return False


# Each theme's own ladder. Do not invent a hue the palette does not have:
# snow stays rose / pink / teal / silver, matrix stays in the greens.
_THEME_ROLES: dict[str, dict[str, str]] = {
    "snow-black": {
        "keyword": "#A06666",
        "string": "#DD9999",
        "function": "#5F8787",
        "type": "#C1C1C1",
        "number": "#A06666",
        "constant": "#5F8787",
        "accent": "#A06666",
    },
    "azure": {
        "keyword": "#8da1c8",
        "string": "#a7d0ec",
        "function": "#61a7d6",
        "type": "#B2C5D9",
        "number": "#6cabda",
        "constant": "#5693C4",
        "accent": "#61a7d6",
    },
    "enter-the-matrix": {
        "keyword": "#7BAE4E",
        "string": "#A8BE5A",
        "function": "#4CAF7E",
        "type": "#7CBCA0",
        "number": "#A8BE5A",
        "constant": "#7BAE4E",
        "accent": "#7BAE4E",
    },
    "space-monkey": {
        "keyword": "#bd4924",
        "string": "#df782d",
        "function": "#fd6883",
        "type": "#f9cc6c",
        "number": "#bd4924",
        "constant": "#fd6883",
        "accent": "#bd4924",
    },
    "no-bad-memories": {
        "keyword": "#E5281A",
        "string": "#E3CB15",
        "function": "#05ADCD",
        "type": "#3FBF4A",
        "number": "#E58B42",
        "constant": "#A82CB8",
        "accent": "#E5281A",
    },
}


def _paint_roles(colors: dict[str, str]) -> dict[str, str]:
    """Syntax roles from this theme's own colors, not a neighboring hue."""
    named = _THEME_ROLES.get(colors.get("_theme_name", ""))
    if named:
        return dict(named)
    ink = ansi_palette(colors)
    bg = colors["background"]
    found: list[str] = []
    for swatch in ink[1:7]:
        _hue, sat, _val = _hsv_of(swatch)
        if sat < 0.16 or color_distance(swatch, bg) < 36:
            continue
        if any(color_distance(swatch, prev) < 26 for prev in found):
            continue
        found.append(swatch)
    found.sort(key=lambda item: _hsv_of(item)[1], reverse=True)
    if not found:
        found = [theme_face(colors)]
    hue, sat, val = _hsv_of(found[0])
    theme = colors.get("_theme_name", "")
    while len(found) < 4:
        step = len(found)
        delta = 0.07 * step
        if _hue_blocked(theme, (hue + delta) % 1.0):
            delta = -0.05 * step
        found.append(
            _from_hsv(
                (hue + delta) % 1.0,
                min(0.62, max(sat, 0.28)),
                min(0.9, max(0.5, val + (0.1 if step % 2 else -0.06))),
            )
        )
    accent = colors["accent"]
    if _hsv_of(accent)[1] < 0.18:
        accent = found[0]
    return {
        "keyword": found[0],
        "string": found[1],
        "function": found[2],
        "type": found[3],
        "number": found[0],
        "constant": found[2],
        "accent": accent,
    }


def render_neovim(colors: dict[str, str]) -> str:
    """One colorscheme per theme, sourced from the current-theme symlink."""
    ink = ansi_palette(colors)
    bg, fg = colors["background"], colors["foreground"]
    comment = comment_ink(colors)
    roles = _paint_roles(colors)
    accent = roles["accent"]
    c1, c2, c3 = roles["keyword"], roles["string"], roles["function"]
    c4 = roles["type"]
    cursor = colors.get("cursor") or fg
    if _hsv_of(cursor)[1] < 0.18:
        cursor = accent
    c8 = ink[8]
    line_nr = c8 if abs(luminance(c8) - luminance(bg)) >= 0.18 else comment
    line = mix_hex(bg, accent, 0.1)
    menu = mix_hex(bg, accent, 0.16)
    visual = mix_hex(bg, accent, 0.42)
    dark = "dark" if luminance(bg) < 0.5 else "light"
    lines = [
        "-- generated by theme-pack from the active omacosy theme",
        'vim.cmd("hi clear")',
        'if vim.fn.exists("syntax_on") == 1 then',
        '  vim.cmd("syntax reset")',
        "end",
        f'vim.o.background = "{dark}"',
        "vim.o.termguicolors = true",
        'vim.g.colors_name = "omacosy"',
    ]
    for i, swatch in enumerate(ink):
        lines.append(f'vim.g.terminal_color_{i} = "{swatch}"')

    def hi(group: str, **opts: str | bool) -> None:
        parts: list[str] = []
        for key, value in opts.items():
            if isinstance(value, bool):
                parts.append(f"{key} = {'true' if value else 'false'}")
            else:
                parts.append(f'{key} = "{value}"')
        lines.append(f'vim.api.nvim_set_hl(0, "{group}", {{ {", ".join(parts)} }})')

    hi("Normal", fg=fg, bg=bg)
    hi("NormalFloat", fg=fg, bg=menu)
    hi("FloatBorder", fg=accent, bg=menu)
    hi("Cursor", fg=text_on(cursor, colors), bg=cursor)
    hi("CursorLine", bg=line)
    hi("CursorLineNr", fg=accent, bold=True)
    hi("LineNr", fg=line_nr)
    hi("Visual", bg=visual)
    hi("Search", fg=text_on(c1, colors), bg=c1)
    hi("IncSearch", fg=text_on(c2, colors), bg=c2)
    hi("Comment", fg=comment, italic=True)
    hi("Constant", fg=roles["constant"])
    hi("String", fg=c2)
    hi("Character", fg=c2)
    hi("Number", fg=roles["number"])
    hi("Boolean", fg=roles["number"])
    hi("Float", fg=roles["number"])
    hi("Identifier", fg=fg)
    hi("Function", fg=c3)
    hi("Statement", fg=c1)
    hi("Keyword", fg=c1)
    hi("Conditional", fg=c1)
    hi("Repeat", fg=c1)
    hi("Operator", fg=c4)
    hi("PreProc", fg=c3)
    hi("Type", fg=c4)
    hi("Special", fg=c2)
    hi("Todo", fg=text_on(accent, colors), bg=accent, bold=True)
    hi("Title", fg=accent, bold=True)
    hi("Directory", fg=c3)
    hi("MatchParen", fg=accent, bold=True)
    hi("StatusLine", fg=fg, bg=menu)
    hi("StatusLineNC", fg=comment, bg=line)
    hi("TabLine", fg=comment, bg=line)
    hi("TabLineSel", fg=text_on(accent, colors), bg=accent)
    hi("Pmenu", fg=fg, bg=menu)
    hi("PmenuSel", fg=text_on(accent, colors), bg=accent)
    hi("WinSeparator", fg=c8)
    hi("VertSplit", fg=c8)
    hi("DiagnosticError", fg=c1)
    hi("DiagnosticWarn", fg=roles["number"])
    hi("DiagnosticInfo", fg=c3)
    hi("DiagnosticHint", fg=c4)
    hi("DiagnosticUnderlineError", sp=c1, undercurl=True)
    hi("DiagnosticUnderlineWarn", sp=roles["number"], undercurl=True)
    hi("DiagnosticUnderlineInfo", sp=c3, undercurl=True)
    hi("DiagnosticUnderlineHint", sp=c4, undercurl=True)
    hi("DiffAdd", fg=c2)
    hi("DiffChange", fg=c3)
    hi("DiffDelete", fg=c1)
    for group, link in (
        ("@comment", "Comment"),
        ("@string", "String"),
        ("@number", "Number"),
        ("@boolean", "Boolean"),
        ("@function", "Function"),
        ("@function.call", "Function"),
        ("@keyword", "Keyword"),
        ("@type", "Type"),
        ("@variable", "Identifier"),
        ("@constant", "Constant"),
        ("@operator", "Operator"),
    ):
        lines.append(f'vim.api.nvim_set_hl(0, "{group}", {{ link = "{link}" }})')
    lines.extend(
        [
            "vim.o.cursorline = true",
            "vim.o.number = true",
            "vim.o.signcolumn = 'yes'",
            "vim.o.laststatus = 3",
            "vim.o.smoothscroll = true",
            'vim.o.fillchars = "eob: ,vert:│,horiz:─"',
            'vim.o.statusline = "%#TabLineSel# %t %m %#StatusLine#%= %Y  %l:%c "',
            "",
        ]
    )
    lines.extend(_cursor_effect_lua(colors.get("_theme_name", ""), roles, line, text_on(accent, colors)))
    return "\n".join(lines)


def _cursor_effect_lua(theme: str, roles: dict[str, str], line_bg: str, cursor_fg: str) -> list[str]:
    """Every theme cycles the cursor through its own colors; some add a motion.

    Resourcing stops the previous timer.
    """
    accent, string, function, kind = roles["accent"], roles["string"], roles["function"], "pulse"
    shape = "n-v-c:ver25-Cursor,i-ci-ve:ver25-Cursor,r-cr:hor20-Cursor"
    if theme == "enter-the-matrix":
        kind, shape = "trail", "n-v-c:block-Cursor,i-ci-ve:ver25-Cursor"
    elif theme == "space-monkey":
        kind, shape = "beacon", "n-v-c:block-Cursor,i-ci-ve:ver30-Cursor"
    elif theme == "azure":
        kind, shape = "glide", "n-v-c:ver30-Cursor,i-ci-ve:ver30-Cursor,r-cr:hor20-Cursor"
    shades: list[str] = []
    for item in (accent, string, function, roles["type"]):
        if all(item.lower() != prev.lower() for prev in shades):
            shades.append(item)
    shade_lua = ", ".join(f'"{item}"' for item in shades)
    return [
        f'vim.o.guicursor = "{shape}"',
        "if _G.omacosy_cursor and _G.omacosy_cursor.timer then",
        "  pcall(function()",
        "    _G.omacosy_cursor.timer:stop()",
        "    _G.omacosy_cursor.timer:close()",
        "  end)",
        "end",
        "_G.omacosy_cursor = { token = 0 }",
        f'local shades = {{ {shade_lua} }}',
        f'local linebg = "{line_bg}"',
        f'local cursorfg = "{cursor_fg}"',
        f'local kind = "{kind}"',
        'local group = vim.api.nvim_create_augroup("omacosy-cursor", { clear = true })',
        "local i = 0",
        "local timer = vim.uv.new_timer()",
        "_G.omacosy_cursor.timer = timer",
        "timer:start(0, 680, vim.schedule_wrap(function()",
        "  i = (i % #shades) + 1",
        "  vim.api.nvim_set_hl(0, \"Cursor\", { fg = cursorfg, bg = shades[i] })",
        "end))",
        "if kind == \"trail\" then",
        "  local ns = vim.api.nvim_create_namespace(\"omacosy-cursor\")",
        "  local marks = {}",
        "  vim.api.nvim_set_hl(0, \"OmacosyTrail1\", { fg = shades[1], bold = true })",
        "  vim.api.nvim_set_hl(0, \"OmacosyTrail2\", { fg = shades[2] })",
        "  vim.api.nvim_set_hl(0, \"OmacosyTrail3\", { fg = shades[3] })",
        "  vim.api.nvim_create_autocmd(\"CursorMoved\", {",
        "    group = group,",
        "    callback = function()",
        "      local buf = vim.api.nvim_get_current_buf()",
        "      local pos = vim.api.nvim_win_get_cursor(0)",
        "      table.insert(marks, 1, { buf, pos[1] - 1, pos[2] })",
        "      while #marks > 3 do table.remove(marks) end",
        "      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)",
        "      for n, mark in ipairs(marks) do",
        "        if mark[1] == buf and mark[3] >= 0 then",
        "          pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark[2], mark[3], {",
        "            end_col = mark[3] + 1,",
        "            hl_group = \"OmacosyTrail\" .. n,",
        "          })",
        "        end",
        "      end",
        "    end,",
        "  })",
        "elseif kind == \"beacon\" then",
        "  local last = { 1, 0 }",
        "  vim.api.nvim_create_autocmd(\"CursorMoved\", {",
        "    group = group,",
        "    callback = function()",
        "      local pos = vim.api.nvim_win_get_cursor(0)",
        "      local jump = math.abs(pos[1] - last[1]) + math.abs(pos[2] - last[2])",
        "      last = { pos[1], pos[2] }",
        "      if jump < 6 then return end",
        "      local id = vim.fn.matchaddpos(\"IncSearch\", { { pos[1], math.max(pos[2], 0) + 1, 2 } })",
        "      vim.defer_fn(function() pcall(vim.fn.matchdelete, id) end, 160)",
        "    end,",
        "  })",
        "elseif kind == \"glide\" then",
        "  vim.api.nvim_create_autocmd(\"CursorMoved\", {",
        "    group = group,",
        "    callback = function()",
        "      _G.omacosy_cursor.token = _G.omacosy_cursor.token + 1",
        "      local token = _G.omacosy_cursor.token",
        "      local bg = linebg",
        "      for step, blend in ipairs({ 50, 28, 10, 0 }) do",
        "        vim.defer_fn(function()",
        "          if token ~= _G.omacosy_cursor.token then return end",
        "          vim.api.nvim_set_hl(0, \"CursorLine\", { bg = bg, blend = blend })",
        "        end, step * 36)",
        "      end",
        "    end,",
        "  })",
        "end",
        "",
    ]


def ensure_nvim_init() -> None:
    init = Path.home() / ".config/nvim/init.lua"
    snippet = (
        "-- omacosy theme skin\n"
        "vim.opt.termguicolors = true\n"
        'local skin = vim.fn.expand("~/.config/omarchy/current/theme/neovim.lua")\n'
        "if vim.fn.filereadable(skin) == 1 then\n"
        "  vim.cmd.source(skin)\n"
        "end\n"
    )
    init.parent.mkdir(parents=True, exist_ok=True)
    if not init.exists():
        init.write_text(snippet, encoding="utf-8")
        return
    text = init.read_text(encoding="utf-8")
    if "-- omacosy theme skin" not in text:
        init.write_text(text.rstrip() + "\n\n" + snippet, encoding="utf-8")


def render_herdr_theme(colors: dict[str, str]) -> str:
    """Herdr chrome from this theme. Panes follow Ghostty via name=terminal."""
    ink = ansi_palette(colors)
    bg, fg = colors["background"], colors["foreground"]
    roles = _paint_roles(colors)
    accent = roles["accent"]
    c1, c2, c3, c4, c5 = roles["keyword"], roles["string"], roles["function"], roles["type"], ink[5]
    # Tint the black/navy/green/brown of the theme itself. Mixing through
    # the gray slot turned snow's rose into a muddy brown.
    surface0 = mix_hex(bg, accent, 0.16)
    surface1 = mix_hex(bg, c2, 0.20)
    # Section headers and dividers are drawn in overlay0. At 10% accent
    # they vanished into the background and the sidebar read as empty.
    overlay0 = mix_hex(bg, comment_ink(colors), 0.70)
    active = mix_hex(bg, accent, 0.38)
    status_cmd = Path(__file__).resolve().parent / "omacosy-herdr-status"
    # The active tab is filled with theme.custom.accent and named in
    # surface_dim, which also draws the sidebar's edge rule. A filled tab
    # read as a block taller than the line above it, so the fill is off
    # ("reset") and the name, like the rule, is one soft mid tone.
    # ui.accent below keeps the theme's own accent.
    # The rule is not wanted at all, so it takes the background color. The
    # active tab's name goes with it; the sidebar and the status strip
    # already say what the tab runs.
    soft = bg
    # Blocked is the theme's red, unless the accent (working) is that red
    # already, as in No Bad Memories; then its yellow.
    blocked = ink[1] if color_distance(ink[1], accent) >= 40 else ink[3]
    done = c2 if color_distance(c2, blocked) >= 40 else ink[2]
    state = (
        f'{{ token = "state_text", rules = ['
        f'{{ equals = "working", fg = "{accent}", bold = true }}, '
        f'{{ equals = "blocked", fg = "{blocked}", bold = true }}, '
        f'{{ equals = "done", fg = "{done}" }}, '
        f'{{ equals = "idle", dim = true }}] }}'
    )
    head_row = f'["state_icon", {{ token = "agent", fg = "{accent}", bold = true }}, {state}]'
    return (
        "# generated by theme-pack from the active omacosy theme\n"
        "[theme]\n"
        'name = "terminal"\n'
        "\n"
        "[theme.custom]\n"
        f'text = "{fg}"\n'
        f'subtext0 = "{comment_ink(colors)}"\n'
        'accent = "reset"\n'
        f'red = "{c1}"\n'
        f'green = "{c2}"\n'
        f'yellow = "{c3}"\n'
        f'blue = "{c4}"\n'
        f'mauve = "{c5}"\n'
        f'surface0 = "{surface0}"\n'
        f'surface1 = "{surface1}"\n'
        # surface_dim: the sidebar's edge rule and the active tab's name.
        f'surface_dim = "{soft}"\n'
        f'overlay0 = "{overlay0}"\n'
        # overlay1 is the status strip at the bottom and its "+" button.
        f'overlay1 = "{mix_hex(fg, bg, 0.40)}"\n'
        # No sidebar slab: its full-height block never lined up with the
        # pane frame, which is drawn through the middle of its edge cells.
        # (A faint slab does not stop Herdr drawing the edge rule either.)
        'sidebar_bg = "reset"\n'
        'panel_bg = "reset"\n'
        f'active_row_bg = "{active}"\n'
        f'selection_bg = "{mix_hex(bg, accent, 0.55)}"\n'
        "\n"
        "[ui]\n"
        # Full bleed: no frames or gaps between panes, the sidebar hidden
        # until prefix+b, and the tab row at the bottom as a status strip.
        'pane_borders = "off"\n'
        "pane_outer_borders = false\n"
        "pane_gaps = false\n"
        "show_agent_labels_on_pane_borders = true\n"
        'status_indicators = "symbols"\n'
        f'accent = "{accent}"\n'
        "hide_tab_bar_when_single_tab = false\n"
        'tab_bar_position = "bottom"\n'
        "tab_bar_right = [\n"
        '  { type = "zoom" },\n'
        f'  {{ type = "command", command = "{status_cmd}", interval_seconds = 3, timeout_seconds = 2 }},\n'
        '  { type = "datetime", format = "%H:%M" },\n'
        "]\n"
        'tab_bar_right_separator = " ╱ "\n'
        "sidebar_start_collapsed = true\n"
        'sidebar_collapsed_mode = "hidden"\n'
        # Hidden until prefix+b, so it can afford room for task titles and
        # branch names instead of cutting them off.
        "sidebar_width = 28\n"
        "sidebar_min_width = 22\n"
        "sidebar_max_width = 36\n"
        "\n"
        # The sidebar as a live board: state in color, what each pane is
        # running ($cmd, reported by omacosy-studio), and for Claude the
        # task in its terminal title.
        "[ui.sidebar.agents]\n"
        "row_gap = 0\n"
        "rows = [\n"
        f"  {head_row},\n"
        f'  [{{ token = "$cmd", fg = "{c3}" }}],\n'
        '  [{ token = "workspace", dim = true }],\n'
        "]\n"
        "\n"
        "[ui.sidebar.agents.rows_by_agent]\n"
        "claude = [\n"
        f"  {head_row},\n"
        f'  [{{ token = "terminal_title_stripped", fg = "{c3}" }}],\n'
        '  [{ token = "workspace", dim = true }],\n'
        "]\n"
        "\n"
        "[ui.sidebar.spaces]\n"
        "row_gap = 0\n"
        "rows = [\n"
        f'  ["state_icon", {{ token = "workspace", fg = "{c2}", bold = true }}],\n'
        f'  [{{ token = "branch", fg = "{c3}" }}, "git_status"],\n'
        "]\n"
    )


def _herdr_preamble(existing: str) -> str:
    """Keep user keys. Drop theme/ui tables, and keys left behind when a header was removed."""
    own = re.compile(
        r"^\[(?:theme(?:\.custom(?:\.light|\.dark)?)?|ui(?:\.sidebar\.(?:agents(?:\.rows_by_agent)?|spaces))?)\]\s*$"
    )
    header = re.compile(r"^\[[A-Za-z0-9_.-]+\]\s*$")
    generated_keys = {
        "name", "text", "subtext0", "accent", "red", "green", "yellow", "blue",
        "mauve", "surface0", "surface1", "surface_dim", "overlay0", "overlay1",
        "sidebar_bg", "panel_bg", "active_row_bg", "selection_bg", "pane_gaps",
        "pane_borders", "pane_outer_borders", "show_agent_labels_on_pane_borders",
        "status_indicators", "row_gap", "rows", "hide_tab_bar_when_single_tab",
        "sidebar_width", "sidebar_min_width", "sidebar_max_width", "tab_bar_position",
        "tab_bar_right", "tab_bar_right_separator", "sidebar_start_collapsed",
        "sidebar_collapsed_mode",
    }
    out: list[str] = []
    dropping = False
    foreign = False
    for line in existing.splitlines():
        if "generated by theme-pack" in line:
            continue
        if own.match(line):
            dropping = True
            foreign = False
            continue
        if header.match(line):
            dropping = False
            foreign = True
            out.append(line)
            continue
        if dropping:
            continue
        if foreign:
            out.append(line)
            continue
        stripped = line.strip()
        if stripped == "" or line.startswith("#"):
            out.append(line)
            continue
        key = re.match(r"^([A-Za-z0-9_-]+)\s*=", line)
        if key and key.group(1) not in generated_keys:
            out.append(line)
    return "\n".join(out).strip()


def write_herdr(theme_dir: Path, colors: dict[str, str]) -> None:
    if not _is_current_theme(theme_dir):
        return
    dest = Path.home() / ".config/herdr/config.toml"
    dest.parent.mkdir(parents=True, exist_ok=True)
    existing = dest.read_text(encoding="utf-8") if dest.is_file() else ""
    kept = _herdr_preamble(existing)
    body = (kept + "\n\n" if kept else "") + render_herdr_theme(colors)
    dest.write_text(body if body.endswith("\n") else body + "\n", encoding="utf-8")
    herdr = shutil.which("herdr")
    if not herdr:
        return
    check = subprocess.run(
        [herdr, "config", "check"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if check.returncode != 0:
        print(check.stdout.strip(), file=sys.stderr)
        return
    # Every Ghostty window runs its own Herdr session (omacosy-studio).
    # A bare reload-config reaches only the session in this process's
    # environment, or the default one from outside Herdr, so every other
    # window kept the old theme. Reload each running session by name.
    for session in _herdr_running_sessions(herdr):
        subprocess.run(
            [herdr, "--session", session, "server", "reload-config"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def _herdr_running_sessions(herdr: str) -> list[str]:
    listed = subprocess.run(
        [herdr, "session", "list", "--json"],
        check=False,
        capture_output=True,
        text=True,
    )
    try:
        sessions = json.loads(listed.stdout).get("sessions") or []
    except (json.JSONDecodeError, AttributeError):
        return []
    return [s["name"] for s in sessions if s.get("running") and s.get("name")]


def render_yazi(colors: dict[str, str]) -> str:
    """Yazi file list in this theme's own colors."""
    bg, fg = colors["background"], colors["foreground"]
    roles = _paint_roles(colors)
    accent, keyword, string = roles["accent"], roles["keyword"], roles["string"]
    function, kind = roles["function"], roles["type"]
    comment = comment_ink(colors)
    on = text_on(accent, colors)
    surface = mix_hex(bg, accent, 0.16)

    def style(**opts: str | bool) -> str:
        parts = []
        for key, value in opts.items():
            if isinstance(value, bool):
                parts.append(f"{key} = {'true' if value else 'false'}")
            else:
                parts.append(f'{key} = "{value}"')
        return "{ " + ", ".join(parts) + " }"

    return "\n".join(
        [
            "# generated by theme-pack from the active omacosy theme",
            "",
            "[mgr]",
            f"cwd = {style(fg=function)}",
            f"find_keyword = {style(fg=string, bold=True, italic=True)}",
            f"find_position = {style(fg=accent, bold=True)}",
            f"marker_copied = {style(fg=string, bg=string)}",
            f"marker_cut = {style(fg=keyword, bg=keyword)}",
            f"marker_selected = {style(fg=kind, bg=kind)}",
            'marker_symbol = "│"',
            f"border_style = {style(fg=accent)}",
            "",
            "[tabs]",
            f"active = {style(fg=on, bg=accent, bold=True)}",
            f"inactive = {style(fg=comment, bg=surface)}",
            'sep_inner = { open = "", close = "" }',
            'sep_outer = { open = "", close = "" }',
            "",
            "[indicator]",
            f"parent = {style(fg=fg, bg=surface)}",
            f"current = {style(fg=on, bg=accent, bold=True)}",
            "preview = { underline = true }",
            'padding = { open = "", close = "" }',
            "",
            "[mode]",
            f"normal_main = {style(fg=on, bg=accent, bold=True)}",
            f"normal_alt = {style(fg=accent, bg=surface)}",
            f"select_main = {style(fg=text_on(string, colors), bg=string, bold=True)}",
            f"select_alt = {style(fg=string, bg=surface)}",
            f"unset_main = {style(fg=text_on(keyword, colors), bg=keyword, bold=True)}",
            f"unset_alt = {style(fg=keyword, bg=surface)}",
            "",
            "[status]",
            'sep_left = { open = "", close = "" }',
            'sep_right = { open = "", close = "" }',
            f"perm_type = {style(fg=function)}",
            f"perm_read = {style(fg=kind)}",
            f"perm_write = {style(fg=keyword)}",
            f"perm_exec = {style(fg=string)}",
            f"progress_normal = {style(fg=function, bg=surface)}",
            f"progress_error = {style(fg=keyword, bg=surface)}",
            "",
            "[which]",
            f"mask = {style(bg=bg)}",
            f"cand = {style(fg=function)}",
            f"rest = {style(fg=comment)}",
            f"desc = {style(fg=string)}",
            f"separator_style = {style(fg=comment)}",
            "",
            "[input]",
            f"border = {style(fg=accent)}",
            f"selected = {style(fg=on, bg=accent)}",
            "",
            "[cmp]",
            f"border = {style(fg=accent)}",
            f"active = {style(fg=on, bg=accent, bold=True)}",
            "",
            "[notify]",
            f"title_info = {style(fg=function)}",
            f"title_warn = {style(fg=kind)}",
            f"title_error = {style(fg=keyword)}",
            "",
            "[filetype]",
            "rules = [",
            f"  {{ mime = \"**/image/*\", fg = \"{kind}\" }},",
            f"  {{ mime = \"**/{{audio,video}}/*\", fg = \"{string}\" }},",
            f"  {{ mime = \"**/application/{{zip,rar,7z*,tar,gzip,xz,zstd,bzip*,lzma,compress,archive,cpio,arj,xar,ms-cab*}}\", fg = \"{keyword}\" }},",
            f"  {{ mime = \"**/application/{{pdf,doc,rtf}}\", fg = \"{function}\" }},",
            f"  {{ url = \"*/\", fg = \"{function}\" }},",
            "]",
            "",
            "[pick]",
            f"border = {style(fg=accent)}",
            f"active = {style(fg=string, bold=True)}",
            "",
            "[tasks]",
            f"border = {style(fg=accent)}",
            f"hovered = {style(fg=string, bold=True)}",
            "",
            "[spot]",
            f"border = {style(fg=accent)}",
            f"title = {style(fg=accent)}",
            f"tbl_col = {style(fg=function)}",
            f"tbl_cell = {style(fg=string, bg=surface)}",
            "",
            "[help]",
            f"border = {style(fg=accent)}",
            f"chord = {style(fg=function)}",
            f"hovered = {{ reversed = true, bold = true }}",
            "",
            "[icon]",
            "dirs = [",
            f"  {{ name = \".config\", text = \"\", fg = \"{string}\" }},",
            f"  {{ name = \".git\", text = \"\", fg = \"{function}\" }},",
            f"  {{ name = \".github\", text = \"\", fg = \"{accent}\" }},",
            f"  {{ name = \"Desktop\", text = \"\", fg = \"{function}\" }},",
            f"  {{ name = \"Documents\", text = \"\", fg = \"{function}\" }},",
            f"  {{ name = \"Downloads\", text = \"\", fg = \"{function}\" }},",
            f"  {{ name = \"Movies\", text = \"\", fg = \"{string}\" }},",
            f"  {{ name = \"Music\", text = \"\", fg = \"{string}\" }},",
            f"  {{ name = \"Pictures\", text = \"\", fg = \"{kind}\" }},",
            f"  {{ name = \"Videos\", text = \"\", fg = \"{string}\" }},",
            "]",
            "conds = [",
            f"  {{ if = \"orphan\", text = \"\", fg = \"{fg}\" }},",
            f"  {{ if = \"link\", text = \"\", fg = \"{comment}\" }},",
            f"  {{ if = \"dummy\", text = \"\", fg = \"{keyword}\" }},",
            f"  {{ if = \"dir & hovered\", text = \"\", fg = \"{accent}\" }},",
            f"  {{ if = \"dir\", text = \"\", fg = \"{function}\" }},",
            f"  {{ if = \"exec\", text = \"\", fg = \"{string}\" }},",
            f"  {{ if = \"!dir\", text = \"\", fg = \"{fg}\" }},",
            "]",
            "",
        ]
    )


def yazi_flavor_name(theme_dir: Path) -> str:
    return f"omacosy-{theme_dir.name}"


def write_yazi(theme_dir: Path, colors: dict[str, str]) -> None:
    text = render_yazi(colors)
    name = yazi_flavor_name(theme_dir)
    flavor = Path.home() / ".config/yazi/flavors" / f"{name}.yazi"
    flavor.mkdir(parents=True, exist_ok=True)
    (flavor / "flavor.toml").write_text(text, encoding="utf-8")
    (flavor / "tmtheme.xml").write_bytes(render_tmtheme(colors))
    (theme_dir / "yazi.toml").write_text(text, encoding="utf-8")
    if not _is_current_theme(theme_dir):
        return
    dest = Path.home() / ".config/yazi/theme.toml"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(
        "\n".join(
            [
                "# generated by theme-pack; the flavor carries this theme's colors",
                "[flavor]",
                f'dark = "{name}"',
                f'light = "{name}"',
                "",
            ]
        ),
        encoding="utf-8",
    )


def _vec3(hex_color: str) -> str:
    r, g, b = hex_to_rgb(hex_color)
    return f"vec3({r / 255:.4f}, {g / 255:.4f}, {b / 255:.4f})"


def _scale_hex(hex_color: str, factor: float) -> str:
    r, g, b = hex_to_rgb(hex_color)
    return "#{:02x}{:02x}{:02x}".format(*(max(0, min(255, int(c * factor))) for c in (r, g, b)))


def _replace_marked(text: str, marker: str, line: str) -> str:
    out = []
    found = False
    for raw in text.splitlines():
        if marker in raw:
            indent = raw[: len(raw) - len(raw.lstrip())]
            out.append(f"{indent}{line}")
            found = True
        else:
            out.append(raw)
    if not found:
        raise RuntimeError(f"cursor template is missing {marker}")
    return "\n".join(out) + "\n"


# Per theme, a layer can be replaced by a shader that brings its own
# colors. It is copied as is, without the theme tint.
CURSOR_LAYER_SWAPS = {
    "no-bad-memories": {
        "cursor_smear_palette.glsl": ("cursor_smear_rainbow.glsl", "cursor-smear-rainbow.glsl"),
        "sparks_palette.glsl": ("sparks_rainbow.glsl", "cursor-sparks-rainbow.glsl"),
    },
}

# The six colors a theme's trails flow through, in loop order. Each theme's
# own colors, picked for the widest spread of hue and lightness it has, so
# the flow reads like No Bad Memories' rainbow without leaving the theme.
# No Bad Memories' smear and sparks keep the real rainbow; this list is for
# its frozen band, which stays in the red-magenta-purple of its accent.
CURSOR_PALETTES = {
    "azure": ("#5656bd", "#6868e6", "#8da1c8", "#add8f5", "#76bbee", "#5693c4"),
    "enter-the-matrix": ("#44b83a", "#7bae4e", "#a8be5a", "#a8c6ae", "#7cbca0", "#4caf7e"),
    "snow-black": ("#a06666", "#dd9999", "#ffffff", "#c1c1c1", "#87abab", "#5f8787"),
    "space-monkey": ("#fd6883", "#bd4924", "#df782d", "#f9cc6c", "#c8e292", "#f8a788"),
    "no-bad-memories": ("#a82cb8", "#c728b8", "#e04a8c", "#ff5a4a", "#e5281a", "#e58b42"),
}


def _cursor_palette(theme: str, roles: dict[str, str]) -> tuple[str, ...]:
    """Six colors for the flowing layers; a theme without a list gets its
    four syntax colors plus a lighter and a darker keyword, ordered by hue."""
    named = CURSOR_PALETTES.get(theme)
    if named:
        return named
    base = [roles["keyword"], roles["string"], roles["type"], roles["function"]]
    base.sort(key=lambda h: _hsv_of(h)[0])
    return (*base, mix_hex(roles["keyword"], "#ffffff", 0.35), _scale_hex(roles["keyword"], 0.7))


def write_cursor_stack(theme_dir: Path, colors: dict[str, str]) -> list[Path]:
    """Four playground shaders, tinted with this theme's colors.

    Bottom to top: frozen, tapered blaze, smear, sparks. Each flows through
    the six colors of _cursor_palette the way No Bad Memories' rainbow
    flows through every hue; blaze runs half a loop apart from frozen.
    A long cursor jump extends those trails to the screen edge.
    CURSOR_LAYER_SWAPS can replace a layer for one theme.
    """
    roles = _paint_roles(colors)
    share = Path(__file__).resolve().parent.parent / "share" / "cursor"
    paths: list[Path] = []
    swaps = CURSOR_LAYER_SWAPS.get(theme_dir.name, {})
    palette = _cursor_palette(theme_dir.name, roles)
    layers = (
        ("cursor_frozen.glsl", "cursor-frozen.glsl"),
        ("cursor_blaze_tapered.glsl", "cursor-blaze-tapered.glsl"),
        ("cursor_smear_palette.glsl", "cursor-smear-gradient.glsl"),
        ("sparks_palette.glsl", "cursor-sparks.glsl"),
    )
    for source_name, dest_name in layers:
        if source_name in swaps:
            swap_source, swap_dest = swaps[source_name]
            dest = theme_dir / swap_dest
            dest.write_text((share / swap_source).read_text(encoding="utf-8"), encoding="utf-8")
            (theme_dir / dest_name).unlink(missing_ok=True)
            paths.append(dest)
            continue
        text = (share / source_name).read_text(encoding="utf-8")
        for n, swatch in enumerate(palette):
            sep = "," if n < len(palette) - 1 else ""
            text = _replace_marked(text, f"omacosy-palette-{n}", f"{_vec3(swatch)}{sep} // omacosy-palette-{n}")
        dest = theme_dir / dest_name
        dest.write_text(text, encoding="utf-8")
        paths.append(dest)
    return paths


def patch_ghostty_cursor(text: str, shader_paths: list[Path]) -> str:
    """Swap the cursor block in an existing theme ghostty.conf."""
    out: list[str] = []
    inserted = False
    saw_thickness = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("cursor-style-blink"):
            out.append(line)
            if not saw_thickness:
                out.append("adjust-cursor-thickness = -50%")
                saw_thickness = True
            continue
        if stripped.startswith("cursor-style"):
            out.append("cursor-style = bar")
            continue
        if stripped.startswith("adjust-cursor-thickness"):
            continue
        if stripped.startswith("custom-shader"):
            if not inserted:
                out.extend(f"custom-shader = {path}" for path in shader_paths)
                inserted = True
            continue
        if stripped.startswith("# cursor stack"):
            continue
        out.append(line)
    if not inserted:
        out.extend(f"custom-shader = {path}" for path in shader_paths)
    return "\n".join(out) + "\n"


# Dark, quiet wallpapers barely show through 0.9, so these themes open up more.
GHOSTTY_OPACITY = {
    "enter-the-matrix": 0.8,
    "snow-black": 0.8,
}

# Ghostty's built-in macos-icon styles, by theme.
GHOSTTY_ICONS = {
    "no-bad-memories": "holographic",
    "enter-the-matrix": "retro",
    "snow-black": "xray",
    "azure": "paper",
}
# custom-style icons drawn from a theme's palette. Screen colors run bottom to top.
GHOSTTY_CUSTOM_ICONS = {
    "space-monkey": {"frame": "beige", "ghost": "#f9cc6c", "screen": ("#1c0e00", "#bd4924")},
}


def ghostty_icon_lines(theme: str, vivid: str, bg: str) -> list[str]:
    if theme in GHOSTTY_ICONS:
        return [f"macos-icon = {GHOSTTY_ICONS[theme]}"]
    style = GHOSTTY_CUSTOM_ICONS.get(theme, {"ghost": vivid, "screen": (bg,)})
    lines = ["macos-icon = custom-style"]
    if "frame" in style:
        lines.append(f"macos-icon-frame = {style['frame']}")
    lines.append(f"macos-icon-ghost-color = {style['ghost'].lstrip('#')}")
    lines.append(f"macos-icon-screen-color = {','.join(c.lstrip('#') for c in style['screen'])}")
    return lines


def write_sidecars(theme_dir: Path, colors: dict[str, str] | None = None) -> dict[str, str]:
    if colors is None:
        colors = normalize(parse_colors(theme_dir / "colors.toml"))
    else:
        colors = normalize(dict(colors))
    colors = restyle_theme(colors, theme_dir.name)
    accent, bg, fg, muted = colors["accent"], colors["background"], colors["foreground"], colors["muted"]
    (theme_dir / "borders.sh").write_text(
        "#!/usr/bin/env bash\n"
        f"export ACTIVE_COLOR={argb(accent, 'e6')}\n"
        f"export INACTIVE_COLOR={argb(muted, '99')}\n",
        encoding="utf-8",
    )
    item_bg = bar_item_bg(colors)
    accent_bar = _chrome_accent(colors)
    icon_bar = mix_hex(accent_bar, fg, 0.32)
    muted_bar = comment_ink(colors)
    if theme_dir.name == "snow-black":
        # Waybar in snow_black: black capsules, white active chip,
        # white glyphs.
        item_bg = "#000000"
        accent_bar = "#FFFFFF"
        icon_bar = "#FFFFFF"
        muted_bar = "#3A4246"
    # Cheatsheet explanations and inactive workspace marks are drawn in
    # MUTED on the bar fill. Comment ink sits on that fill; snow's
    # #3A4246 on black cannot be read. Lift toward a light neutral,
    # still well under the label.
    lift = 0.62 if theme_dir.name == "snow-black" else 0.42
    muted_bar = mix_hex(muted_bar, "#cfd3d6", lift)
    bar_red = punch_on(colors["color1"], bg)
    bar_green = punch_on(colors["color2"], bg)
    bar_yellow = punch_on(colors["color3"], bg)
    bar_solid = bg
    label_bar = fg
    if theme_dir.name == "no-bad-memories":
        # Lacquer-red pills. The theme red would vanish on them, so the
        # glyphs, the active chip and the low-battery mark turn cream.
        item_bg = "#E0140C"
        accent_bar = "#FFF3E8"
        icon_bar = "#FFF3E8"
        muted_bar = "#FFD6CC"
        bar_red = "#FFF3E8"
        bar_green = "#9CF25A"
        bar_yellow = "#FFE45C"
        # BAR_BG_SOLID fills the bar's menus and cheatsheet; the terminal
        # violet there did not match the red pills.
        bar_solid = "#E0140C"
        label_bar = "#FFF3E8"
    (theme_dir / "sketchybar.sh").write_text(
        "#!/usr/bin/env bash\n"
        f"export BAR_COLOR={argb(bg, 'e6')}\n"
        f"export BAR_BG_SOLID={argb(bar_solid)}\n"
        f"export ITEM_BG={argb(item_bg)}\n"
        f"export ACCENT={argb(accent_bar)}\n"
        f"export LABEL_COLOR={argb(label_bar)}\n"
        f"export ICON_COLOR={argb(icon_bar)}\n"
        f"export MUTED={argb(muted_bar)}\n"
        f"export RED={argb(bar_red)}\n"
        f"export GREEN={argb(bar_green)}\n"
        f"export YELLOW={argb(bar_yellow)}\n",
        encoding="utf-8",
    )
    ink = ansi_palette(colors)
    vivid = _paint_roles(colors)["accent"]
    sel = colors.get("_theme_selection") or colors["selection_background"]
    sel_fg = colors.get("selection_foreground") or text_on(sel, colors)
    authored_cursor = colors.get("cursor")
    if (
        authored_cursor
        and _hsv_of(authored_cursor)[1] >= 0.25
        and abs(luminance(authored_cursor) - luminance(bg)) >= 0.22
    ):
        cursor = authored_cursor
    else:
        cursor = vivid
    cursor_fg = text_on(cursor, colors)
    split = comment_ink(colors)
    ghost = [
        f"font-family = {FONT}",
        f"font-family = {FONT_FALLBACK}",
        "font-size = 14",
        f"background = {bg.lstrip('#')}",
        f"foreground = {fg.lstrip('#')}",
        "cursor-style = bar",
        "cursor-style-blink = false",
        "adjust-cursor-thickness = -50%",
        f"cursor-color = {cursor.lstrip('#')}",
        *[f"custom-shader = {path}" for path in write_cursor_stack(theme_dir, colors)],
        f"cursor-text = {cursor_fg.lstrip('#')}",
        f"selection-background = {sel.lstrip('#')}",
        f"selection-foreground = {sel_fg.lstrip('#')}",
        f"background-opacity = {GHOSTTY_OPACITY.get(theme_dir.name, 0.9)}",
        "background-blur = true",
        "window-padding-x = 8",
        "window-padding-y = 6",
        "minimum-contrast = 1",
        f"split-divider-color = {split.lstrip('#')}",
        f"unfocused-split-fill = {mix_hex(bg, vivid, 0.28).lstrip('#')}",
        "unfocused-split-opacity = 0.92",
        *ghostty_icon_lines(theme_dir.name, vivid, bg),
    ]
    ghost.extend(f"palette = {i}={swatch.lstrip('#')}" for i, swatch in enumerate(palette_256(colors)))
    (theme_dir / "ghostty.conf").write_text("\n".join(ghost) + "\n", encoding="utf-8")
    normal = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
    (theme_dir / "alacritty.toml").write_text(
        "[colors.primary]\n"
        f'background = "{bg}"\n'
        f'foreground = "{fg}"\n'
        "[colors.cursor]\n"
        f'cursor = "{cursor}"\n'
        f'text = "{cursor_fg}"\n'
        "[colors.selection]\n"
        f'background = "{sel}"\n'
        f'text = "{sel_fg}"\n'
        "[colors.normal]\n"
        + "\n".join(f'{name} = "{ink[i]}"' for i, name in enumerate(normal))
        + "\n[colors.bright]\n"
        + "\n".join(f'{name} = "{ink[i + 8]}"' for i, name in enumerate(normal))
        + "\n",
        encoding="utf-8",
    )
    kitty = [
        f"font_family      {FONT}",
        f"background       {bg}",
        f"foreground       {fg}",
        f"cursor           {cursor}",
        f"cursor_text_color {cursor_fg}",
        f"selection_background {sel}",
        f"selection_foreground {sel_fg}",
    ]
    kitty.extend(f"color{i} {ink[i]}" for i in range(16))
    (theme_dir / "kitty.conf").write_text("\n".join(kitty) + "\n", encoding="utf-8")
    (theme_dir / "starship.toml").write_text(render_starship(colors), encoding="utf-8")
    (theme_dir / "shell.env").write_text(render_shell_env(colors), encoding="utf-8")
    (theme_dir / "btop.theme").write_text(render_btop(colors), encoding="utf-8")
    (theme_dir / "bat.tmTheme").write_bytes(render_tmtheme(colors))
    (theme_dir / "neovim.lua").write_text(render_neovim(colors), encoding="utf-8")
    ensure_nvim_init()
    write_herdr(theme_dir, colors)
    write_yazi(theme_dir, colors)
    return colors


def write_nscolor(domain: str, key: str, hex_color: str) -> None:
    r, g, b = (c / 255 for c in hex_to_rgb(hex_color))
    try:
        from AppKit import NSColor  # type: ignore
        from Foundation import NSKeyedArchiver  # type: ignore

        color = NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, b, 1.0)
        archived = NSKeyedArchiver.archivedDataWithRootObject_requiringSecureCoding_error_(color, False, None)
        data = archived[0] if isinstance(archived, tuple) else archived
        subprocess.run(
            ["defaults", "write", domain, key, "-data", bytes(data).hex()],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    except Exception:
        subprocess.run(
            ["defaults", "write", domain, key, f"{r:.3f} {g:.3f} {b:.3f}"],
            check=False,
        )


def write_typora(colors: dict[str, str]) -> None:
    TYPO.mkdir(parents=True, exist_ok=True)
    bg, fg, acc = colors["background"], colors["foreground"], colors["accent"]
    muted = colors["muted"]
    sidebar = colors.get("color0", bg)
    sel = colors.get("selection_background", acc)
    code = mix_hex(bg, muted, 0.4)
    hover = colors.get("lighter_background", mix_hex(bg, fg, 0.1))
    (TYPO / "omacosy.css").write_text(
        f"""@import "night/mermaid.dark.css";
@import "night/codeblock.dark.css";
@import "night/sourcemode.dark.css";

:root {{
  --bg-color: {bg};
  --side-bar-bg-color: {sidebar};
  --text-color: {fg};
  --select-text-bg-color: {sel};
  --item-hover-bg-color: {hover};
  --item-hover-text-color: {fg};
  --control-text-color: {fg};
  --control-text-hover-color: {acc};
  --window-border: 1px solid {muted};
  --active-file-bg-color: {sel};
  --active-file-border-color: {acc};
  --active-file-text-color: {fg};
  --primary-color: {acc};
  --rawblock-edit-panel-bd: {code};
  --search-select-bg-color: {acc};
}}

html, body {{
  font-family: "{FONT}", "{FONT_FALLBACK}", ui-sans-serif, system-ui, sans-serif;
  background: {bg} !important;
  color: {fg} !important;
  fill: {fg};
  line-height: 1.65;
}}
#write {{
  background: {bg} !important;
  color: {fg} !important;
  max-width: 860px;
  margin: 0 auto;
  padding: 30px;
}}
#typora-sidebar, .sidebar-content, #file-library, .file-list-item, .outline-content {{
  background: {sidebar} !important;
  color: {fg} !important;
}}
.file-list-item.active, .file-tree-node.active {{
  background: {sel} !important;
}}
a, h1, h2, h3, h4 {{ color: {acc}; }}
code, tt, .md-fences, pre, .md-rawblock {{
  background: {code} !important;
  color: {fg};
}}
blockquote {{ border-left: 3px solid {acc}; color: {muted}; }}
hr {{ border-color: {muted}; }}
.CodeMirror, .cm-s-typora-default, .md-source-wrp, .CodeMirror-scroll {{
  background: {bg} !important;
  color: {fg} !important;
}}
.CodeMirror-gutters {{
  background: {sidebar} !important;
  border-color: {muted} !important;
}}
.CodeMirror-cursor {{ border-left-color: {acc} !important; }}
""",
        encoding="utf-8",
    )
    r, g, b = hex_to_rgb(bg)
    dark = luminance(bg) < 0.55
    defaults_write("abnerworks.Typora", "theme", "string", "omacosy")
    defaults_write("abnerworks.Typora", "darkTheme", "string", "omacosy")
    defaults_write("abnerworks.Typora", "useDarkTheme", "bool", "true" if dark else "false")
    defaults_write("abnerworks.Typora", "useSeparateDarkTheme", "bool", "true")
    defaults_write("abnerworks.Typora", "backgroundColor", "string", f"rgba({r}, {g}, {b}, 256)")
    subprocess.run(
        ["defaults", "write", "abnerworks.Typora", "backgroundColor2", "-array",
         "-int", str(r), "-int", str(g), "-int", str(b), "-int", "1"],
        check=False,
    )


def write_textedit(colors: dict[str, str]) -> None:
    bg, fg = colors["background"], colors["foreground"]
    subprocess.run(["defaults", "write", "com.apple.TextEdit", "NSFont", f"{FONT} 14"], check=False)
    subprocess.run(["defaults", "write", "com.apple.TextEdit", "NSFixedPitchFont", f"{FONT} 14"], check=False)
    subprocess.run(["defaults", "write", "com.apple.TextEdit", "RichText", "-int", "0"], check=False)
    subprocess.run(["defaults", "write", "com.apple.TextEdit", "AlwaysLightBackground", "-bool", "false"], check=False)
    write_nscolor("com.apple.TextEdit", "NSColor", fg)
    write_nscolor("com.apple.TextEdit", "textBackgroundColor", bg)
    write_nscolor("com.apple.TextEdit", "backgroundColor", bg)


def write_cursor(colors: dict[str, str]) -> None:
    write_editor_settings(CURSOR, colors)


def write_vscode(colors: dict[str, str]) -> None:
    write_editor_settings(VSCODE, colors)


def write_editor_settings(path: Path, colors: dict[str, str]) -> None:
    if not path.parent.is_dir():
        if path == VSCODE and Path("/Applications/Visual Studio Code.app").is_dir():
            path.parent.mkdir(parents=True, exist_ok=True)
        else:
            return
    data = {}
    if path.is_file():
        try:
            data = json.loads(path.read_text())
        except Exception:
            data = {}
    if not isinstance(data, dict):
        data = {}
    dark = luminance(colors["background"]) < 0.55
    data["window.autoDetectColorScheme"] = True
    data["workbench.preferredDarkColorTheme"] = "Visual Studio Dark"
    data["workbench.preferredLightColorTheme"] = "Quiet Light"
    data["workbench.colorTheme"] = "Visual Studio Dark" if dark else "Quiet Light"
    data["workbench.colorCustomizations"] = _cursor_colors(colors)
    data["editor.tokenColorCustomizations"] = _token_colors(colors)
    data["editor.semanticTokenColorCustomizations"] = {"rules": _semantic_colors(colors)}
    data["editor.fontFamily"] = f"'{FONT}', '{FONT_FALLBACK}', Menlo, monospace"
    data["editor.fontLigatures"] = False
    path.write_text(json.dumps(data, indent=4) + "\n", encoding="utf-8")


def _chrome_accent(colors: dict[str, str]) -> str:
    accent = colors["accent"]
    if abs(luminance(accent) - luminance(colors["background"])) < 0.16:
        return punch_on(accent, colors["background"])
    return accent


def _cursor_colors(colors: dict[str, str]) -> dict[str, str]:
    ink = ansi_palette(colors)
    bg, fg = colors["background"], colors["foreground"]
    accent = _chrome_accent(colors)
    # Editor text stays the foreground color, so the selection wash has to
    # contrast with that, not with a second color the editor will not use.
    sel = contrasting_bg(fg, colors["selection_background"])
    comment = comment_ink(colors)
    panel = mix_hex(bg, fg, 0.05)
    names = ("Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White")
    chrome = {
        "editor.background": bg,
        "editor.foreground": fg,
        "editor.selectionBackground": sel + "aa",
        "editor.inactiveSelectionBackground": sel + "55",
        "editor.lineHighlightBackground": mix_hex(bg, sel, 0.28),
        "editorCursor.foreground": colors["cursor"] if abs(luminance(colors["cursor"]) - luminance(bg)) >= 0.25 else fg,
        "editorLineNumber.foreground": comment,
        "editorLineNumber.activeForeground": accent,
        "editorWidget.background": panel,
        "editorWidget.border": comment,
        "editorSuggestWidget.background": panel,
        "editorSuggestWidget.foreground": fg,
        "editorSuggestWidget.selectedBackground": sel,
        "editorSuggestWidget.highlightForeground": ink[3],
        "editor.findMatchBackground": ink[3] + "66",
        "editor.findMatchHighlightBackground": ink[3] + "33",
        "editorGutter.addedBackground": ink[2],
        "editorGutter.modifiedBackground": ink[3],
        "editorGutter.deletedBackground": ink[1],
        "sideBar.background": ink[0],
        "sideBar.foreground": fg,
        "sideBarSectionHeader.background": panel,
        "activityBar.background": ink[0],
        "activityBar.foreground": accent,
        "activityBar.inactiveForeground": comment,
        "statusBar.background": ink[0],
        "statusBar.foreground": fg,
        "statusBar.noFolderBackground": ink[0],
        "statusBar.noFolderForeground": fg,
        "statusBar.debuggingBackground": ink[1],
        "titleBar.activeBackground": ink[0],
        "titleBar.activeForeground": fg,
        "titleBar.inactiveBackground": bg,
        "titleBar.inactiveForeground": comment,
        "tab.activeBackground": bg,
        "tab.activeForeground": fg,
        "tab.inactiveBackground": ink[0],
        "tab.inactiveForeground": comment,
        "tab.activeBorder": accent,
        "tab.activeBorderTop": accent,
        "focusBorder": accent,
        "button.background": accent,
        "button.foreground": text_on(accent, colors),
        "input.background": panel,
        "input.foreground": fg,
        "input.placeholderForeground": comment,
        "dropdown.background": panel,
        "panel.background": ink[0],
        "panel.border": comment,
        "list.activeSelectionBackground": sel,
        "list.activeSelectionForeground": text_on(sel, colors),
        "list.hoverBackground": mix_hex(bg, sel, 0.4),
        "list.inactiveSelectionBackground": sel + "66",
        "gitDecoration.addedResourceForeground": ink[2],
        "gitDecoration.modifiedResourceForeground": ink[3],
        "gitDecoration.deletedResourceForeground": ink[1],
        "gitDecoration.untrackedResourceForeground": ink[6],
        "peekView.border": accent,
        "peekViewResult.selectionBackground": sel,
        "breadcrumb.foreground": comment,
        "breadcrumb.focusForeground": fg,
        "terminal.background": bg,
        "terminal.foreground": fg,
        "terminalCursor.foreground": accent,
    }
    for i, name in enumerate(names):
        chrome[f"terminal.ansi{name}"] = ink[i]
        chrome[f"terminal.ansiBright{name}"] = ink[i + 8]
    return chrome


def _token_colors(colors: dict[str, str]) -> dict[str, object]:
    ink = syntax_inks(colors)
    rules = []
    for scope, key, style in SYNTAX_SCOPES:
        settings: dict[str, str] = {"foreground": ink[key]}
        if style:
            settings["fontStyle"] = style
        rules.append({"scope": scope, "settings": settings})
    return {
        "comments": ink["comment"],
        "strings": ink["string"],
        "keywords": ink["keyword"],
        "numbers": ink["number"],
        "functions": ink["function"],
        "types": ink["type"],
        "variables": ink["variable"],
        "textMateRules": rules,
    }


def _semantic_colors(colors: dict[str, str]) -> dict[str, str | dict[str, str]]:
    ink = syntax_inks(colors)
    mapping = {
        "comment": "comment",
        "string": "string",
        "keyword": "keyword",
        "number": "number",
        "function": "function",
        "method": "method",
        "variable": "variable",
        "parameter": "parameter",
        "property": "property",
        "type": "type",
        "class": "class",
        "namespace": "namespace",
        "enum": "type",
        "macro": "decorator",
        "operator": "operator",
        "decorator": "decorator",
        "regexp": "regexp",
    }
    rules: dict[str, str | dict[str, str]] = {}
    for name, key in mapping.items():
        rules[name] = {"foreground": ink[key], "fontStyle": "italic"} if name == "comment" else ink[key]
    return rules


def render_shell_env(colors: dict[str, str]) -> str:
    ink = ansi_palette(colors)
    fg, bg = colors["foreground"], colors["background"]
    c1, c2, c3, c4, c5, c6 = ink[1], ink[2], ink[3], ink[4], ink[5], ink[6]
    comment = comment_ink(colors)
    sel = colors["selection_background"]
    sel_fg = text_on(sel, colors)
    hl = c3 if color_distance(c3, sel) >= 48 else c1
    eza = ":".join(
        [
            f"di={rgb_ansi(c4)}",
            f"ex={rgb_ansi(c2)}",
            f"ln={rgb_ansi(c6)}",
            f"or={rgb_ansi(c1)}",
            f"fi={rgb_ansi(fg)}",
            f"pi={rgb_ansi(c3)}",
            f"so={rgb_ansi(c5)}",
            f"bd={rgb_ansi(c4)}",
            f"cd={rgb_ansi(c6)}",
            f"sn={rgb_ansi(comment)}",
            f"sb={rgb_ansi(comment)}",
            f"da={rgb_ansi(comment)}",
            f"uu={rgb_ansi(c4)}",
            f"un={rgb_ansi(comment)}",
            f"gu={rgb_ansi(c2)}",
            f"gn={rgb_ansi(comment)}",
            f"hd={rgb_ansi(c4)}",
            f"im={rgb_ansi(c5)}",
            f"vi={rgb_ansi(c4)}",
            f"mu={rgb_ansi(c3)}",
            f"lo={rgb_ansi(c2)}",
            f"cr={rgb_ansi(c3)}",
            f"do={rgb_ansi(fg)}",
            f"co={rgb_ansi(c3)}",
            f"sc={rgb_ansi(c6)}",
            f"tm={rgb_ansi(comment)}",
            f"cm={rgb_ansi(comment)}",
            f"bu={rgb_ansi(c1)}",
        ]
    )
    ls = ":".join(
        [
            f"di={rgb_ansi(c4)}",
            f"ln={rgb_ansi(c6)}",
            f"ex={rgb_ansi(c2)}",
            f"or={rgb_ansi(c1)}",
            f"pi={rgb_ansi(c3)}",
            f"so={rgb_ansi(c5)}",
            f"bd={rgb_ansi(c4)}",
            f"cd={rgb_ansi(c6)}",
            f"*.md={rgb_ansi(c6)}",
            f"*.py={rgb_ansi(c3)}",
            f"*.rs={rgb_ansi(c1)}",
            f"*.go={rgb_ansi(c6)}",
            f"*.js={rgb_ansi(c3)}",
            f"*.ts={rgb_ansi(c4)}",
            f"*.json={rgb_ansi(c5)}",
            f"*.toml={rgb_ansi(c5)}",
            f"*.yml={rgb_ansi(c5)}",
            f"*.yaml={rgb_ansi(c5)}",
            f"*.sh={rgb_ansi(c2)}",
            f"*.zsh={rgb_ansi(c2)}",
            f"*.swift={rgb_ansi(c1)}",
            f"*.c={rgb_ansi(c4)}",
            f"*.h={rgb_ansi(c6)}",
            f"*.cpp={rgb_ansi(c4)}",
            f"*.rb={rgb_ansi(c1)}",
            f"*.lua={rgb_ansi(c4)}",
        ]
    )
    border = comment if color_distance(comment, bg) >= 28 else c6
    fzf = (
        f"--color=fg:{fg},bg:{bg},hl:{c3},"
        f"fg+:{sel_fg},bg+:{sel},hl+:{hl},"
        f"info:{c3},prompt:{c4},pointer:{c2},"
        f"marker:{c2},spinner:{c6},header:{c4},"
        f"border:{border},gutter:{bg},query:{fg}"
    )
    return (
        "# generated by theme-pack — sourced from zshrc\n"
        "export BAT_THEME='omacosy'\n"
        f"export FZF_DEFAULT_OPTS='{fzf}'\n"
        f"export EZA_COLORS='{eza}'\n"
        f"export LS_COLORS='{ls}'\n"
        "# Herdr does not answer Neovim's underline probe. Ghostty's TERM\n"
        "# skips that probe, so colored underlines survive inside a pane.\n"
        'if [[ -n ${HERDR_ENV:-} ]]; then\n'
        '  nvim() { TERM=xterm-ghostty command nvim "$@"; }\n'
        "fi\n"
    )


def render_btop(colors: dict[str, str]) -> str:
    bg, fg = colors["background"], colors["foreground"]
    acc = _chrome_accent(colors)
    paints = _surface_colors(colors)
    def at(index: int) -> str:
        return paints[index % len(paints)]
    c1, c2, c3, c4, c6 = at(2), at(0), at(1), at(3), at(4 % len(paints))
    muted = comment_ink(colors)
    sel = colors["selection_background"]
    return (
        "# generated by theme-pack from the active omacosy theme\n"
        f'theme[main_bg]="{bg}"\n'
        f'theme[main_fg]="{fg}"\n'
        f'theme[title]="{fg}"\n'
        f'theme[hi_fg]="{acc}"\n'
        f'theme[selected_bg]="{sel}"\n'
        f'theme[selected_fg]="{text_on(sel, colors)}"\n'
        f'theme[inactive_fg]="{muted}"\n'
        f'theme[proc_misc]="{acc}"\n'
        f'theme[cpu_box]="{acc}"\n'
        f'theme[mem_box]="{c4}"\n'
        f'theme[net_box]="{c6}"\n'
        f'theme[proc_box]="{c3}"\n'
        f'theme[div_line]="{muted}"\n'
        f'theme[temp_start]="{c2}"\n'
        f'theme[temp_mid]="{c3}"\n'
        f'theme[temp_end]="{c1}"\n'
        f'theme[cpu_start]="{c2}"\n'
        f'theme[cpu_mid]="{c3}"\n'
        f'theme[cpu_end]="{c1}"\n'
        f'theme[free_start]="{c2}"\n'
        f'theme[free_mid]="{acc}"\n'
        f'theme[free_end]="{c4}"\n'
        f'theme[cached_start]="{c4}"\n'
        f'theme[cached_mid]="{c6}"\n'
        f'theme[cached_end]="{acc}"\n'
        f'theme[available_start]="{c6}"\n'
        f'theme[available_mid]="{acc}"\n'
        f'theme[available_end]="{c4}"\n'
        f'theme[used_start]="{c3}"\n'
        f'theme[used_mid]="{c1}"\n'
        f'theme[used_end]="{c1}"\n'
        f'theme[download_start]="{c4}"\n'
        f'theme[download_mid]="{c6}"\n'
        f'theme[download_end]="{c2}"\n'
        f'theme[upload_start]="{c6}"\n'
        f'theme[upload_mid]="{c1}"\n'
        f'theme[upload_end]="{c3}"\n'
        f'theme[process_start]="{c2}"\n'
        f'theme[process_mid]="{acc}"\n'
        f'theme[process_end]="{c1}"\n'
    )


def render_tmtheme(colors: dict[str, str]) -> bytes:
    ink = syntax_inks(colors)
    bg, fg = colors["background"], colors["foreground"]
    sel = contrasting_bg(fg, colors["selection_background"])
    settings: list[dict[str, object]] = [
        {
            "settings": {
                "background": bg,
                "foreground": fg,
                "caret": _chrome_accent(colors),
                "lineHighlight": mix_hex(bg, sel, 0.35),
                "selection": sel,
                "invisibles": comment_ink(colors),
            }
        }
    ]
    for scope, key, style in SYNTAX_SCOPES:
        rule: dict[str, str] = {"foreground": ink[key]}
        if style:
            rule["fontStyle"] = style
        settings.append({"name": scope, "scope": scope, "settings": rule})
    data = {
        "name": "omacosy",
        "uuid": "a7c0e5d2-4b11-4f3a-9d8e-0c05b0c05b01",
        "semanticClass": "theme.omacosy",
        "colorSpaceName": "sRGB",
        "settings": settings,
    }
    return plistlib.dumps(data, fmt=plistlib.FMT_XML)


def write_btop(colors: dict[str, str]) -> None:
    BTOP_THEME.parent.mkdir(parents=True, exist_ok=True)
    BTOP_THEME.write_text(render_btop(colors), encoding="utf-8")
    if BTOP_CONF.is_file():
        raw = BTOP_CONF.read_text(encoding="utf-8")
        updated = re.sub(r"^color_theme\s*=\s*.*$", 'color_theme = "omacosy"', raw, flags=re.M)
        if updated == raw and "color_theme" not in raw:
            updated = 'color_theme = "omacosy"\n' + raw
        BTOP_CONF.write_text(updated, encoding="utf-8")
    else:
        BTOP_CONF.parent.mkdir(parents=True, exist_ok=True)
        BTOP_CONF.write_text('color_theme = "omacosy"\n', encoding="utf-8")


def write_bat(colors: dict[str, str]) -> None:
    BAT_THEME.parent.mkdir(parents=True, exist_ok=True)
    BAT_THEME.write_bytes(render_tmtheme(colors))
    BAT_CONF.parent.mkdir(parents=True, exist_ok=True)
    if BAT_CONF.is_file():
        raw = BAT_CONF.read_text(encoding="utf-8")
        if re.search(r"^--theme=", raw, flags=re.M):
            raw = re.sub(r"^--theme=.*$", '--theme="omacosy"', raw, flags=re.M)
        else:
            raw = '--theme="omacosy"\n' + raw
        BAT_CONF.write_text(raw, encoding="utf-8")
    else:
        BAT_CONF.write_text('--theme="omacosy"\n', encoding="utf-8")
    bat = shutil.which("bat")
    if bat:
        subprocess.run([bat, "cache", "--build"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def write_lazygit(colors: dict[str, str]) -> None:
    ink = ansi_palette(colors)
    fg = colors["foreground"]
    acc = _chrome_accent(colors)
    # lazygit paints the selected row with defaultFgColor, so the bar has
    # to be the color that contrasts with that text.
    sel = contrasting_bg(fg, colors["selection_background"])
    inactive = mix_hex(colors["background"], sel, 0.55)
    comment = comment_ink(colors)
    block = (
        "gui:\n"
        "  theme:\n"
        f'    activeBorderColor:\n      - "{acc}"\n      - bold\n'
        f'    inactiveBorderColor:\n      - "{comment}"\n'
        f'    searchingActiveBorderColor:\n      - "{ink[3]}"\n      - bold\n'
        f'    optionsTextColor:\n      - "{ink[3]}"\n'
        f'    selectedLineBgColor:\n      - "{sel}"\n'
        f'    inactiveViewSelectedLineBgColor:\n      - "{inactive}"\n'
        f'    cherryPickedCommitBgColor:\n      - "{comment}"\n'
        f'    cherryPickedCommitFgColor:\n      - "{ink[2]}"\n'
        f'    markedBaseCommitBgColor:\n      - "{ink[4]}"\n'
        f'    markedBaseCommitFgColor:\n      - "{text_on(ink[4], colors)}"\n'
        f'    unstagedChangesColor:\n      - "{ink[1]}"\n'
        f'    defaultFgColor:\n      - "{fg}"\n'
        "git:\n"
        "  paging:\n"
        "    colorArg: always\n"
        "    pager: delta --paging=never --line-numbers\n"
    )
    LAZYGIT.parent.mkdir(parents=True, exist_ok=True)
    raw = LAZYGIT.read_text(encoding="utf-8") if LAZYGIT.is_file() else ""
    raw = re.sub(r"(?ms)^gui:\n(?:[ \t].*\n)*", "", raw)
    raw = re.sub(r"(?ms)^git:\n(?:[ \t].*\n)*", "", raw).strip()
    text = block if not raw else block + "\n" + raw + "\n"
    LAZYGIT.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")


def write_delta(colors: dict[str, str]) -> None:
    ink = ansi_palette(colors)
    bg, acc = colors["background"], _chrome_accent(colors)
    plus_ink = ink[2]
    plus = mix_hex(bg, plus_ink, 0.5)
    minus = mix_hex(bg, ink[1], 0.5)
    plus_e = mix_hex(bg, plus_ink, 0.78)
    minus_e = mix_hex(bg, ink[1], 0.78)
    text = (
        "[delta]\n"
        "    syntax-theme = omacosy\n"
        "    line-numbers = true\n"
        "    navigate = true\n"
        f'    plus-style = "syntax {plus}"\n'
        f'    minus-style = "syntax {minus}"\n'
        f'    plus-emph-style = "syntax {plus_e}"\n'
        f'    minus-emph-style = "syntax {minus_e}"\n'
        f'    line-numbers-minus-style = "{ink[1]}"\n'
        f'    line-numbers-plus-style = "{plus_ink}"\n'
        f'    line-numbers-zero-style = "{comment_ink(colors)}"\n'
        f'    file-style = "bold {acc}"\n'
        f'    file-decoration-style = "{acc} ul"\n'
        '    hunk-header-style = "syntax bold"\n'
        f'    hunk-header-decoration-style = "{acc} box"\n'
        f'    commit-style = "bold {ink[3]}"\n'
        f'    commit-decoration-style = "{ink[3]} box"\n'
    )
    DELTA_GIT.parent.mkdir(parents=True, exist_ok=True)
    DELTA_GIT.write_text(text, encoding="utf-8")
    raw = GITCONFIG.read_text(encoding="utf-8") if GITCONFIG.is_file() else ""
    if "delta.gitconfig" not in raw:
        extra = f"[include]\n    path = {DELTA_GIT}\n"
        if raw and not raw.endswith("\n"):
            raw += "\n"
        GITCONFIG.write_text(raw + extra, encoding="utf-8")


LOGO_NAMES = {"omarchy.webp", "omarchy.png", "omarchy.jpg", "omarchy.jpeg"}


def is_lock_art(path: Path) -> bool:
    if not path.is_file():
        return False
    name = path.name.lower()
    if name in LOGO_NAMES or "preview" in name:
        return False
    size = path.stat().st_size
    if name.startswith("unlock") and size > 80_000:
        return True
    if "omarchy" in name and size > 30_000:
        return True
    if name.startswith(("lock.", "lock-", "lock_")) and size > 30_000:
        return True
    return False


def real_backgrounds(theme_dir: Path) -> list[Path]:
    bg = theme_dir / "backgrounds"
    if not bg.is_dir():
        return []
    out = []
    for p in sorted(bg.iterdir()):
        if not p.is_file() or p.suffix.lower() not in {".jpg", ".jpeg", ".png", ".webp", ".heic"}:
            continue
        if is_lock_art(p) or p.name.lower() in {"lock.png", "lock-ui.png"}:
            continue
        out.append(p)
    return out


def desktop_already(desktop: Path) -> bool:
    helper = Path.home() / ".local/bin/omacosy-helper"
    if not helper.is_file():
        return False
    out = subprocess.run(
        [str(helper), "wallpaper", "get"],
        check=False,
        capture_output=True,
        text=True,
    )
    lines = [ln.strip() for ln in (out.stdout or "").splitlines() if ln.strip()]
    if not lines:
        return False
    try:
        target = desktop.resolve()
    except OSError:
        return False
    for ln in lines:
        try:
            if Path(ln).resolve() != target:
                return False
        except OSError:
            return False
    return True


def set_desktop_image(desktop: Path) -> None:
    """Swap the picture in place.

    Do not rewrite Index.plist and do not kill WallpaperAgent. On macOS 27
    that restart paints the built-in Golden Gate desktop until the agent
    reads the store again, and writing the store from this process raises
    a file-access prompt on every theme switch.
    """
    if not desktop.is_file() or desktop_already(desktop):
        return
    helper = Path.home() / ".local/bin/omacosy-helper"
    if helper.is_file():
        subprocess.run(
            [str(helper), "wallpaper", str(desktop)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def apply_wallpaper(theme_dir: Path, wallpaper: Path | None = None) -> None:
    """Make sure the desktop shows a real background of this theme."""
    walls = real_backgrounds(theme_dir)
    desktop = wallpaper if wallpaper and wallpaper.is_file() else (walls[0] if walls else None)
    if desktop and (is_lock_art(desktop) or desktop.name.lower() in {"lock.png", "lock-ui.png"}):
        desktop = walls[0] if walls else None
    if desktop:
        set_desktop_image(desktop)


def defaults_write(domain: str, key: str, typ: str, value: str) -> None:
    subprocess.run(["defaults", "write", domain, key, f"-{typ}", value], check=False)


def read_default(domain: str, key: str) -> str | None:
    out = subprocess.run(
        ["/usr/bin/defaults", "read", domain, key],
        check=False,
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        return None
    text = (out.stdout or "").strip()
    return text or None


def sync_global_preferences() -> None:
    """Flush NSGlobalDomain before any process is told to re-read it.

    A notification that lands first makes AppKit cache the previous accent.
    Killing cfprefsd to force a re-read is what used to race that cache
    and take down clients mid-lookup.
    """
    try:
        from CoreFoundation import CFPreferencesAppSynchronize, kCFPreferencesAnyApplication

        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    except Exception:
        pass


# CoreUI repaints traffic lights only after BOTH of these, variant first.
CHROME_COLOR_NOTIFY = (
    "AppleAquaColorVariantChanged",
    "AppleColorPreferencesChangedNotification",
)


def post_chrome_notifications(*, appearance: bool = False) -> None:
    """Tell running AppKit apps the accent, highlight, and traffic lights changed.

    System Settings posts the distributed notifications. notifyutil is a
    separate channel and does not reach CoreUI, so it is not used here.
    No AppleScript: controlling System Events prompts on every switch
    when the sender is a shell launched from AeroSpace.
    """
    names = list(CHROME_COLOR_NOTIFY)
    if appearance:
        names.append("AppleInterfaceThemeChangedNotification")
    try:
        from Foundation import NSDistributedNotificationCenter

        dnc = NSDistributedNotificationCenter.defaultCenter()
        for name in names:
            dnc.postNotificationName_object_userInfo_deliverImmediately_(name, None, None, True)
    except Exception:
        pass
    try:
        from CoreFoundation import (
            CFNotificationCenterGetDistributedCenter,
            CFNotificationCenterPostNotification,
        )

        center = CFNotificationCenterGetDistributedCenter()
        for name in names:
            CFNotificationCenterPostNotification(center, name, None, None, True)
    except Exception:
        pass


def _appkit():
    import ctypes

    import AppKit

    AppKit.NSApplication.sharedApplication()
    return ctypes.CDLL("/System/Library/Frameworks/AppKit.framework/AppKit")


def publish_user_accent(accent: int) -> None:
    """Store the accent and tell every open window.

    The second argument is the notify flag. Without it AppKit writes the
    accent and leaves traffic lights and the input method on the old color.
    """
    try:
        import ctypes

        appkit = _appkit()
        setter = appkit.NSColorSetUserAccentColor
        setter.restype = ctypes.c_bool
        # The second argument is a register-width flag. A ctypes bool can
        # arrive as zero, which stores the accent and skips the broadcast.
        setter.argtypes = [ctypes.c_int64, ctypes.c_int]
        getter = appkit.NSColorGetUserAccentColor
        getter.restype = ctypes.c_int64
        getter.argtypes = []
        target = int(accent)
        # An unchanged index returns without notifying, so windows keep the
        # previous buttons. Step to another accent, then back to the target.
        if int(getter()) == target:
            setter(ctypes.c_int64(0 if target != 0 else 4), 1)
        setter(ctypes.c_int64(target), 1)
    except Exception:
        pass


def publish_user_highlight(hex_color: str) -> None:
    """Push the candidate-bar color the way the Appearance pane does.

    Key -2 is the custom highlight. The third argument notifies the input
    method; without it the new RGB stays on disk and the bar keeps the
    previous color.
    """
    try:
        import ctypes

        from AppKit import NSColor

        appkit = _appkit()
        r, g, b = hex_to_rgb(hex_color)
        color = NSColor.colorWithSRGBRed_green_blue_alpha_(r / 255, g / 255, b / 255, 1.0)
        setter = appkit.NSColorSetUserHighlightColor
        setter.restype = ctypes.c_bool
        setter.argtypes = [ctypes.c_int64, ctypes.c_void_p, ctypes.c_int]
        setter(ctypes.c_int64(-2), color.__c_void_p__(), 1)
    except Exception:
        pass


def flush_distributed_notifications() -> None:
    """Let the accent broadcast leave this process.

    NSColorSetUserAccentColor posts with the two-argument method, which
    waits for a run-loop turn. The theme switch exits immediately, so
    without this turn the open windows never hear the new color.
    """
    try:
        from Foundation import NSDate, NSRunLoop

        NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.4))
    except Exception:
        pass


def refresh_cached_chrome() -> None:
    """Reload the input candidate window.

    That window ignores a normal terminate and keeps the highlight it
    read at login. SIGKILL lets launchd start a new one, which reads the
    color just written. TextInputSwitcher stays up so the keyboard does
    not wedge. Dock and SystemUIServer stay up too: restarting them races
    omacosy-menubar-hide and can wedge WindowServer.
    """
    subprocess.run(
        ["/usr/bin/killall", "Finder"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for proc in ("SCIM_Extension", "CursorUIViewService"):
        subprocess.run(
            ["/usr/bin/killall", "-9", proc],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def _pid_runs(pid: str, name: str) -> bool:
    """Whether that pid is a process whose executable name starts with `name`."""
    out = subprocess.run(
        ["/bin/ps", "-p", pid, "-o", "comm="], check=False, capture_output=True, text=True
    ).stdout.strip()
    return bool(out) and Path(out).name.startswith(name)


GHOSTTY_RELOAD_CACHE = Path.home() / ".local/state/omacosy/ghostty-reload"


def _ghostty_reloads_on_usr2(binary: Path) -> bool:
    """Whether this Ghostty build reloads its config on SIGUSR2.

    A build without the handler takes the signal's default action, which
    ends the process and every terminal in it. So the answer comes from
    the binary itself, and is remembered until the binary changes.
    """
    try:
        st = binary.stat()
    except OSError:
        return False
    stamp = f"{binary} {st.st_size} {st.st_mtime_ns}"
    try:
        cached = GHOSTTY_RELOAD_CACHE.read_text(encoding="utf-8").splitlines()
        if len(cached) == 2 and cached[0] == stamp:
            return cached[1] == "yes"
    except OSError:
        pass
    try:
        handled = b"in response to SIGUSR2" in binary.read_bytes()
    except OSError:
        return False
    try:
        GHOSTTY_RELOAD_CACHE.parent.mkdir(parents=True, exist_ok=True)
        GHOSTTY_RELOAD_CACHE.write_text(f"{stamp}\n{'yes' if handled else 'no'}\n", encoding="utf-8")
    except OSError:
        pass
    return handled


def reload_ghostty() -> None:
    """Have every running Ghostty re-read its config.

    This used to run `ghostty +reload-config`. That is not an action:
    Ghostty prints "invalid action" and exits 1, so open terminals kept
    the previous theme's palette until they were restarted.
    """
    out = subprocess.run(
        ["/bin/ps", "-axo", "pid=,comm="], check=False, capture_output=True, text=True
    ).stdout
    for line in out.splitlines():
        pid, _, comm = line.strip().partition(" ")
        comm = comm.strip()
        if not pid.isdigit() or not comm.endswith("/Contents/MacOS/ghostty"):
            continue
        if not _ghostty_reloads_on_usr2(Path(comm)):
            continue
        try:
            os.kill(int(pid), signal.SIGUSR2)
        except OSError:
            pass


def apply_macos(colors: dict[str, str]) -> None:
    accent = colors["accent"]
    apple = colors.get("_apple_accent") or str(nearest_apple_accent(accent))
    highlight_hex = colors.get("_ime_highlight") or accent
    r, g, b = hex_to_rgb(highlight_hex)
    highlight = f"{r / 255:.6f} {g / 255:.6f} {b / 255:.6f} Other"
    wall_light = colors.get("_wallpaper_light")
    if wall_light == "1":
        dark = False
    elif wall_light == "0":
        dark = True
    else:
        dark = luminance(colors["background"]) < 0.55
    appearance_changed = False
    if dark:
        if read_default("-g", "AppleInterfaceStyle") != "Dark":
            defaults_write("-g", "AppleInterfaceStyle", "string", "Dark")
            appearance_changed = True
    elif read_default("-g", "AppleInterfaceStyle") is not None:
        subprocess.run(
            ["defaults", "delete", "-g", "AppleInterfaceStyle"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        appearance_changed = True
    defaults_write("-g", "AppleAccentColor", "int", apple)
    defaults_write("-g", "AppleAquaColorVariant", "int", "6" if apple == "-1" else "1")
    defaults_write("-g", "AppleHighlightColor", "string", highlight)
    publish_user_accent(int(apple))
    publish_user_highlight(highlight_hex)
    replace_file(Path.home() / ".config/starship.toml", render_starship(colors))
    ghostty_user = Path.home() / ".config/ghostty/config"
    if ghostty_user.is_file():
        ghostty_user.touch()
    reload_ghostty()
    # An overview built before it learnt to re-read the theme samples its
    # border colour once, at startup. Dropping it makes the next swipe
    # start one that reads the new colour. The pid file outlives a reboot
    # and the number is handed to some other process afterwards, so the
    # process is checked before it is signalled.
    overview_pid = Path.home() / ".local/state/omacosy/overview.pid"
    if overview_pid.is_file():
        pid = overview_pid.read_text(encoding="utf-8").strip()
        if pid.isdigit() and _pid_runs(pid, "omacosy-overview"):
            try:
                os.kill(int(pid), signal.SIGTERM)
            except OSError:
                pass
    sync_global_preferences()
    post_chrome_notifications(appearance=appearance_changed)
    flush_distributed_notifications()
    refresh_cached_chrome()
    post_chrome_notifications(appearance=False)
    flush_distributed_notifications()


def write_iterm(colors: dict[str, str]) -> None:
    dest = Path.home() / "Library/Application Support/iTerm2/DynamicProfiles"
    if not dest.parent.is_dir():
        return
    dest.mkdir(parents=True, exist_ok=True)
    def rgb(key: str) -> dict[str, float]:
        r, g, b = hex_to_rgb(colors[key])
        return {"Red Component": r / 255, "Green Component": g / 255, "Blue Component": b / 255}

    profile = {
        "Profiles": [
            {
                "Name": "omacosy",
                "Guid": "omacosy-dynamic",
                "Dynamic Profile Title": "omacosy",
                "Background Color": rgb("background"),
                "Foreground Color": rgb("foreground"),
                "Cursor Color": rgb("cursor"),
                "Selection Color": rgb("selection_background"),
                "Selected Text Color": rgb("selection_foreground"),
                "Normal Font": f"{FONT} 14",
                "Use Non-ASCII Font": False,
            }
        ]
    }
    (dest / "omacosy.json").write_text(json.dumps(profile, indent=2) + "\n", encoding="utf-8")


def apply(theme_dir: Path, wallpaper: Path | None = None, color_mode: str | None = None) -> None:
    base = normalize(parse_colors(theme_dir / "colors.toml"))
    if color_mode:
        save_color_mode(theme_dir, color_mode)
    else:
        color_mode = load_color_mode(theme_dir)
    colors = restyle_theme(apply_color_mode(base, wallpaper, color_mode), theme_dir.name)
    write_sidecars(theme_dir, colors)
    if theme_dir.name in IME_BLUE_THEMES:
        colors["_apple_accent"] = "4"
        colors["_ime_highlight"] = APPLE_HEX[4]
    if theme_dir.name == "snow-black":
        # Finder, Safari, and Preview only accept a system accent.
        # Graphite is the gray one. The candidate bar can take the
        # theme's own light gray, which is brighter than graphite.
        # Wallpaper sampling would otherwise hand Finder the green of the eyes.
        colors["_apple_accent"] = "-1"
        colors["_ime_highlight"] = "#C8CECE"
    apply_macos(colors)
    write_typora(colors)
    write_textedit(colors)
    write_cursor(colors)
    write_vscode(colors)
    write_iterm(colors)
    write_btop(colors)
    write_bat(colors)
    write_lazygit(colors)
    write_delta(colors)
    apply_wallpaper(theme_dir, wallpaper)
    # Wallpaper is settled. Ask windows to retint without restarting
    # Finder, Preview, or the wallpaper agent.
    post_chrome_notifications(appearance=False)


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] not in {"apply", "apply-sidecars", "apply-wallpaper"}:
        print("usage: theme-pack.py apply|apply-sidecars <theme-dir> [wallpaper] [color-mode]", file=sys.stderr)
        return 2
    theme_dir = Path(sys.argv[2])
    wallpaper = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None
    color_mode = sys.argv[4] if len(sys.argv) > 4 else None
    if sys.argv[1] == "apply-sidecars":
        write_sidecars(theme_dir)
        return 0
    if sys.argv[1] == "apply-wallpaper":
        apply_wallpaper(theme_dir, wallpaper)
        return 0
    apply(theme_dir, wallpaper, color_mode)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
