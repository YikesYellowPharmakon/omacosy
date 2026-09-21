#!/usr/bin/env python3
"""Render VOPARCHY in Omarchy's Delta Corps Priest 1 FIGlet font.

The stock font only hangs the R one row below the baseline. Stretch every
letter by that same extra row so the wordmark is uniformly taller.
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent
FONT = HERE / "fonts" / "delta_corps_priest_1.flf"
OUT = HERE / "logo.txt"


def load_flf(path: Path) -> dict[str, list[str]]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    header = lines[0].split()
    height = int(header[1])
    comment = int(header[5])
    hardblank = lines[0][5] if lines[0].startswith("flf2a") else "$"
    i = 1 + comment
    glyphs: dict[str, list[str]] = {}
    code = 32
    while i + height <= len(lines) and code < 127:
        raw = lines[i : i + height]
        i += height
        rows = []
        for row in raw:
            row = row.rstrip("\n")
            if row.endswith("@@"):
                row = row[:-2]
            elif row.endswith("@"):
                row = row[:-1]
            rows.append(row.replace(hardblank, " "))
        glyphs[chr(code)] = rows
        code += 1
    return glyphs


def stretch(glyph: list[str]) -> list[str]:
    """Give every letter the extra bottom row the R already has."""
    rows = list(glyph)
    if not rows or rows[-1].strip():
        return rows
    last = next((i for i in range(len(rows) - 1, -1, -1) if rows[i].strip()), None)
    if last is None or last == 0:
        return rows
    stem = rows[last - 1]
    rows[last] = stem
    rows[-1] = glyph[last]
    return rows


def render(text: str, glyphs: dict[str, list[str]]) -> str:
    height = max((len(g) for g in glyphs.values()), default=0)
    rows = [""] * height
    for ch in text:
        glyph = glyphs.get(ch) or glyphs.get(" ")
        if glyph is None:
            continue
        for r, line in enumerate(glyph):
            rows[r] += line
    while rows and not rows[-1].strip():
        rows.pop()
    return "\n".join(row.rstrip() for row in rows) + "\n"


def main() -> None:
    glyphs = load_flf(FONT)
    for ch, glyph in list(glyphs.items()):
        if ch.isalpha():
            glyphs[ch] = stretch(glyph)
    art = render("VOPARCHY", glyphs)
    OUT.write_text(art)
    lines = art.splitlines()
    print(f"wrote {OUT} {max(map(len, lines), default=0)}x{len(lines)}")


if __name__ == "__main__":
    main()
