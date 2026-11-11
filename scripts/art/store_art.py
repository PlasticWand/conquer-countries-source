"""Art for the shops: skin previews and the Arsenal's card illustrations.

Usage, from the project root:
    python scripts/art/store_art.py [referenceRoot]

- Skin previews: each pattern in src/shared/Store/Skins.luau tiled over a
  territory colour (the darker shade where a bit is set, as the map draws it),
  128x128 cells packed into assets/ui/skins-1.png (8x8 cells).
- Arsenal cards: 520x260 before/after scenes built from OpenFront's icons
  (resources/images, CC BY-SA 4.0) on our own layouts, packed into
  assets/ui/arsenal-1.png (2 columns).
Writes src/client/Ui/StoreArt.luau (cells; page ids kept across runs).
"""
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render import render  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REF = Path(sys.argv[1] if len(sys.argv) > 1 else "../reference/openfront-v0.35.2")
IMAGES = REF / "resources" / "images"
OUT = ROOT / "assets" / "ui"
BASE = (86, 132, 201)
SHADE = (52, 88, 150)


def skins():
    text = (ROOT / "src" / "shared" / "Store" / "Skins.luau").read_text(encoding="utf-8")
    out = []
    for m in re.finditer(r'\{ id = "(\w+)", name = "[^"]+", rarity = "\w+", scale = (\d), rows = \{([^}]*)\} \}', text):
        rows = re.findall(r'"([#.]+)"', m.group(3))
        out.append((m.group(1), int(m.group(2)), rows))
    return out


def skin_page():
    cell = 128
    items = skins()
    img = Image.new("RGBA", (8 * cell, 8 * cell), (0, 0, 0, 0))
    cells = {}
    for i, (sid, scale, rows) in enumerate(items):
        tile = Image.new("RGBA", (cell, cell), BASE + (255,))
        draw = ImageDraw.Draw(tile)
        px = 4 * (2 ** scale)  # preview pixels per pattern cell
        h, w = len(rows), len(rows[0])
        for y in range(0, cell, px):
            for x in range(0, cell, px):
                if rows[(y // px) % h][(x // px) % w] == "#":
                    draw.rectangle((x, y, x + px - 1, y + px - 1), fill=SHADE + (255,))
        col, row = i % 8, i // 8
        img.paste(tile, (col * cell, row * cell))
        cells[sid] = (1, col, row)
    img.save(OUT / "skins-1.png")
    return cells


def icon(name: str, size: int, x: int, y: int, color: str = "#ffffff") -> str:
    filt = "brightness(0) invert(1)" if color == "#ffffff" else "brightness(0)"
    return (f'<img src="{(IMAGES / name).as_uri()}" style="position:absolute;left:{x}px;top:{y}px;width:{size}px;'
            f'height:{size}px;object-fit:contain;filter:{filt} drop-shadow(0 3px 2px rgba(0,0,0,.35))">')


def label(text: str, x: int, y: int, size: int = 22, color: str = "#fff") -> str:
    return (f'<div style="position:absolute;left:{x}px;top:{y}px;font:900 {size}px Arial Black,Arial;color:{color};'
            f'text-shadow:0 2px 0 #222,0 0 4px #222">{text}</div>')


def scene(left: str, right: str, inner: str) -> str:
    return (f'<div style="position:relative;width:520px;height:260px;overflow:hidden;border-radius:0">'
            f'<div style="position:absolute;left:0;top:0;width:260px;height:260px;background:{left}"></div>'
            f'<div style="position:absolute;left:260px;top:0;width:260px;height:260px;background:{right}"></div>'
            f'<div style="position:absolute;left:258px;top:0;width:4px;height:260px;background:rgba(0,0,0,.25)"></div>'
            f'{inner}</div>')


CARDS = {
    "w_reinforce": scene("#b58ae0", "#e8867a",
        icon("TroopIconWhite.svg", 70, 40, 60) + icon("TroopIconWhite.svg", 70, 100, 90) + icon("TroopIconWhite.svg", 70, 40, 130)
        + label("24.0K", 40, 205, 24) + label("&#187;&#187;&#187;", 200, 105, 46, "#ffe08a")
        + icon("CityIconWhite.svg", 64, 360, 120) + label("42.7K", 330, 30, 30)),
    "w_mega": scene("#b58ae0", "#7fcf8a",
        '<div style="position:absolute;left:300px;top:40px;width:190px;height:190px;border-radius:50%;'
        'background:radial-gradient(circle,#fff6c8 0%,#ffb534 35%,#ff5b2e 62%,rgba(255,91,46,0) 72%)"></div>'
        + icon("NukeIconWhite.svg", 80, 50, 40) + icon("MushroomCloudIconWhite.svg", 110, 340, 60)
        + label("4x", 70, 160, 54, "#ffe08a") + label("BLAST", 150, 175, 26)),
    "b_double": ('<div style="position:relative;width:520px;height:260px;overflow:hidden;'
        'background:radial-gradient(circle at 40% 55%,#7a5a1a 0%,#3a2a10 55%,#1c1408 100%)">'
        '<div style="position:absolute;left:150px;top:40px;font:900 170px Arial Black;color:#ffc93c;'
        'text-shadow:0 6px 0 #a8741a">&#9733;</div>' + label("2X", 330, 40, 80, "#fff") + label("PAYOUT &#215;2", 90, 190, 34, "#ffe08a") + '</div>'),
}


def arsenal_page():
    cells = {}
    cols = 2
    rows = (len(CARDS) + cols - 1) // cols
    parts = []
    for i, (wid, body) in enumerate(CARDS.items()):
        col, row = i % cols, i // cols
        parts.append(f'<div style="position:absolute;left:{col * 520}px;top:{row * 260}px">{body}</div>')
        cells[wid] = (1, col, row)
    page = OUT / "arsenal-1.html"
    page.write_text(f'<!doctype html><html><body style="margin:0;width:{cols * 520}px;height:{rows * 260}px;'
                    f'position:relative;background:#000">{"".join(parts)}</body></html>', encoding="utf-8")
    render(page, OUT / "arsenal-1.png", cols * 520, rows * 260, transparent=False)
    page.unlink()
    return cells


def main():
    skin_cells = skin_page()
    card_cells = arsenal_page()
    path = ROOT / "src" / "client" / "Ui" / "StoreArt.luau"
    old = path.read_text(encoding="utf-8") if path.exists() else ""
    def keep(name):
        m = re.search(name + r' = "(rbxassetid://\d+|)"', old)
        return m.group(1) if m else ""
    lines = [
        "--!strict",
        "-- Generated by scripts/art/store_art.py; page ids kept across runs.",
        "-- Skin previews are our own patterns; Arsenal cards use OpenFront icons (CC BY-SA 4.0).",
        "return {",
        f'\tSKINS = "{keep("SKINS")}",',
        f'\tARSENAL = "{keep("ARSENAL")}",',
        "\tskinCell = 128,",
        "\tcardW = 520,",
        "\tcardH = 260,",
        "\tskins = {",
    ]
    for sid, (_, col, row) in skin_cells.items():
        lines.append(f"\t\t{sid} = {{ {col}, {row} }},")
    lines += ["\t},", "\tcards = {"]
    for wid, (_, col, row) in card_cells.items():
        lines.append(f"\t\t{wid} = {{ {col}, {row} }},")
    lines += ["\t},", "}", ""]
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(f"{len(skin_cells)} skins, {len(card_cells)} arsenal cards")


if __name__ == "__main__":
    main()
