"""Draw the imported maps as vintage field maps for the dossier main menu.

Usage, from the project root:
    python -I scripts/art/field_maps.py [referenceRoot]

Reads each map's resources/maps/<dir>/map4x.bin (OpenFront, CC BY-SA 4.0,
credit "OpenFront"): one terrain byte per tile, land bit 7, shore bit 6,
ocean bit 5, magnitude bits 0..4. Draws sepia land shaded by height on a
blue-grey sea, ink coastlines, a faint grid and paper grain, fitted into a
256x192 cell. Pages are 1024x960 (4x5 cells). Writes
assets/ui/field-maps-<n>.png and src/client/Ui/FieldMaps.luau (folder -> page
and cell). Upload the pages with scripts/upload_images.py --openfront and put
the ids in FieldMaps.PAGES.
"""
import json
import random
import re
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
REF = Path(sys.argv[1] if len(sys.argv) > 1 else "../reference/openfront-v0.35.2")
CELL_W, CELL_H = 256, 192
COLS, ROWS = 4, 5

SEA = (132, 152, 150)
SEA_DEEP = (112, 133, 134)
LAND_LOW = (222, 199, 148)
LAND_HIGH = (168, 128, 82)
INK = (52, 40, 28)


def source_dir(init_text: str) -> str:
    return re.search(r'source = "openfront-v0\.35\.2/([^"]+)"', init_text).group(1)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw(src: str) -> Image.Image:
    folder = REF / "resources" / "maps" / src
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    w, h = manifest["map4x"]["width"], manifest["map4x"]["height"]
    data = (folder / "map4x.bin").read_bytes()[: w * h]
    # Fit the map into the cell (at least 2x oversampled, then reduced).
    scale = min(CELL_W * 2 / w, CELL_H * 2 / h)
    out_w, out_h = max(1, round(w * scale)), max(1, round(h * scale))
    img = Image.new("RGB", (w, h))
    land = Image.new("L", (w, h))
    px, lp = img.load(), land.load()
    for y in range(h):
        row = y * w
        for x in range(w):
            t = data[row + x]
            # Magnitude 31 is impassable: the map's masked-off corners.
            if t & 0x80 and (t & 0x1F) != 31:
                mag = (t & 0x1F) / 31
                px[x, y] = lerp(LAND_LOW, LAND_HIGH, min(1.0, mag * 1.6))
                lp[x, y] = 255
            else:
                # Deeper water further from shore reads as darker.
                px[x, y] = SEA if t & 0x40 or (t & 0x1F) < 4 else SEA_DEEP
    img = img.resize((out_w, out_h), Image.LANCZOS)
    land = land.resize((out_w, out_h), Image.BILINEAR).point(lambda v: 255 if v > 127 else 0)
    # Fill lakes and rivers a few pixels across: at this size they would
    # only ink as dots and scribbles.
    # A blur and a low threshold closes them with round, not boxy, shores.
    filled = land.filter(ImageFilter.GaussianBlur(2.5)).point(lambda v: 255 if v > 90 else 0)
    lakes = ImageChops.subtract(filled, land)
    img.paste(Image.new("RGB", img.size, LAND_LOW), (0, 0), lakes)
    # Ink coastline: the edge of the land mask, thickened to read at size.
    edge = filled.filter(ImageFilter.FIND_EDGES).filter(ImageFilter.MaxFilter(3))
    img.paste(Image.new("RGB", img.size, INK), (0, 0), edge.point(lambda v: 210 if v > 40 else 0))
    # Centre it on sea in the cell.
    cell = Image.new("RGB", (CELL_W * 2, CELL_H * 2), SEA_DEEP)
    cell.paste(img, ((CELL_W * 2 - out_w) // 2, (CELL_H * 2 - out_h) // 2))
    # A faint grid.
    grid = ImageDraw.Draw(cell)
    for gx in range(0, CELL_W * 2, 48):
        grid.line([(gx, 0), (gx, CELL_H * 2)], fill=lerp(INK, SEA, 0.82), width=1)
    for gy in range(0, CELL_H * 2, 48):
        grid.line([(0, gy), (CELL_W * 2, gy)], fill=lerp(INK, SEA, 0.82), width=1)
    cell = cell.resize((CELL_W, CELL_H), Image.LANCZOS)
    # Paper grain and a faded, warm vignette.
    rng = random.Random(src)
    noise = Image.new("L", cell.size)
    noise.putdata([128 + rng.randint(-18, 18) for _ in range(CELL_W * CELL_H)])
    noise = noise.filter(ImageFilter.GaussianBlur(0.6))
    cell = ImageChops.overlay(cell, Image.merge("RGB", (noise, noise, noise)))
    vignette = Image.new("L", cell.size, 0)
    ImageDraw.Draw(vignette).rectangle([0, 0, CELL_W - 1, CELL_H - 1], outline=255, width=1)
    vignette = vignette.filter(ImageFilter.GaussianBlur(22)).point(lambda v: min(255, v * 3))
    cell.paste(Image.new("RGB", cell.size, (120, 92, 58)), (0, 0), vignette.point(lambda v: v // 3))
    return cell


def main() -> None:
    maps = []
    for init in sorted((ROOT / "src" / "maps").glob("*/init.luau")):
        maps.append((init.parent.name, source_dir(init.read_text(encoding="utf-8"))))
    per_page = COLS * ROWS
    pages, cells = [], {}
    for i, (folder, src) in enumerate(maps):
        page, slot = divmod(i, per_page)
        if page == len(pages):
            pages.append(Image.new("RGB", (COLS * CELL_W, ROWS * CELL_H), SEA_DEEP))
        col, row = slot % COLS, slot // COLS
        pages[page].paste(draw(src), (col * CELL_W, row * CELL_H))
        cells[folder] = (page + 1, col, row)
        print(folder, src)
    out = ROOT / "assets" / "ui"
    for n, p in enumerate(pages, 1):
        p.save(out / f"field-maps-{n}.png")
    module = ROOT / "src" / "client" / "Ui" / "FieldMaps.luau"
    old = module.read_text(encoding="utf-8") if module.exists() else ""
    kept = re.search(r"PAGES = \{([^}]*)\}", old)
    lines = [
        "--!strict",
        "-- Generated by scripts/art/field_maps.py: the maps as vintage field maps for",
        "-- the dossier main menu. PAGES are the uploaded ids (kept across",
        "-- regenerations; re-upload changed pages). Drawn from OpenFront map data,",
        '-- CC BY-SA 4.0, credit "OpenFront".',
        "return {",
        f"\tcellW = {CELL_W},",
        f"\tcellH = {CELL_H},",
        f"\tPAGES = {{{kept.group(1) if kept else ''}}},",
        "\tcells = {",
    ]
    for folder, (page, col, row) in cells.items():
        lines.append(f"\t\t{folder} = {{ {page}, {col}, {row} }},")
    lines += ["\t},", "}", ""]
    module.write_text("\n".join(lines), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
