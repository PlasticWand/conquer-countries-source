"""Original Conquest Campaign Pass flag graphics, appended after event flags.

Flat 160x120 design sources; cloth treatments are in art/flags-cloth/out/.
Season 1 names, rarities and IDs match Store/Pass and Store/FlagList.

    python scripts/art/campaign_flags.py --pack

After make_sheets.py and cut.py 30, packs just these cells into the existing
own/card atlas pages, preserving every other pixel. Does not change runtime
lookups or uploaded IDs; prints the entries for Claude to wire after upload.
"""

CAMPAIGN = {
    "campaign1_a": ("Field Marshal", "epic", "campaign",
        '<rect width="160" height="120" fill="#173f35"/>'
        '<rect y="0" width="160" height="8" fill="#cba34d"/>'
        '<rect y="112" width="160" height="8" fill="#cba34d"/>'
        '<path d="M80 14l10 12-10 12-10-12z" fill="#f3d27a"/>'
        '<g fill="none" stroke="#f3d27a" stroke-width="8" stroke-linejoin="miter">'
        '<path d="M42 62l38-20 38 20M42 80l38-20 38 20M42 98l38-20 38 20"/></g>'),
    "campaign1_b": ("Siege Standard", "epic", "campaign",
        '<rect width="160" height="120" fill="#681f2e"/>'
        '<path d="M0 94L126 0h34v26L34 120H0z" fill="#421a25"/>'
        '<rect x="8" y="8" width="144" height="104" fill="none" stroke="#cba34d" stroke-width="4"/>'
        '<path d="M48 92V44H44V24h14v10h14V24h16v10h14V24h14v20h-4v48z" fill="#eddbb6"/>'
        '<path d="M69 92V72a11 11 0 0 1 22 0v20z" fill="#421a25"/>'
        '<path d="M53 53h54M53 61h10M97 61h10M53 79h10M97 79h10" stroke="#b9955f" stroke-width="3"/>'
        '<rect x="42" y="92" width="76" height="9" fill="#cba34d"/>'),
    "campaign1_c": ("Iron Banner", "legendary", "campaign",
        '<rect width="160" height="120" fill="#22272d"/>'
        '<rect x="5" y="5" width="150" height="110" fill="none" stroke="#e4bc59" stroke-width="4"/>'
        '<rect x="12" y="12" width="136" height="96" fill="none" stroke="#9d7937" stroke-width="2"/>'
        '<path d="M80 20l27 10v30c0 18-13 30-27 39-14-9-27-21-27-39V30z" fill="#b8c5cc" stroke="#edf1ed" stroke-width="3"/>'
        '<path d="M80 24v70c12-9 23-20 23-35V33z" fill="#778893"/>'
        '<path d="M80 36l10 22-10 23-10-23z" fill="#f4d47f"/>'
        '<g fill="none" stroke="#d6ae50" stroke-width="3" stroke-linecap="round">'
        '<path d="M66 101C35 91 28 67 35 43M94 101c31-10 38-34 31-58"/></g>'
        '<g fill="#e4bc59">'
        '<path d="M35 55C23 53 22 45 23 40c9 2 13 7 12 15zM34 66C21 65 18 58 18 52c10 1 15 6 16 14zM38 79C25 80 20 74 19 68c10-1 17 3 19 11zM45 90C33 94 26 89 23 83c10-3 17-1 22 7zM57 99C47 107 39 104 34 100c8-7 16-7 23-1z"/>'
        '<path d="M125 55c12-2 13-10 12-15-9 2-13 7-12 15zM126 66c13-1 16-8 16-14-10 1-15 6-16 14zM122 79c13 1 18-5 19-11-10-1-17 3-19 11zM115 90c12 4 19-1 22-7-10-3-17-1-22 7zM103 99c10 8 18 5 23 1-8-7-16-7-23-1z"/></g>'),
}


def pack_pages() -> None:
    import json
    import re
    from pathlib import Path

    from PIL import Image, ImageOps
    import flags as flag_art

    root = Path(__file__).resolve().parents[2]
    # Card order is country flags, then own flags. Read the existing country
    # count from its generated table, without requiring the reference clone.
    table = (root / "src/client/Ui/FlagArt.luau").read_text(encoding="utf-8").split("cardCells =", 1)[0]
    country_count = len(re.findall(r'\["f_[a-z]{2}"\]', table))
    assert country_count > 0
    own_order = list(flag_art.OWN)
    pages = {}
    lookups = {}
    for key in CAMPAIGN:
        code = f"o_{key}"
        flag = Image.open(flag_art.CLOTH / f"{code}.png").convert("RGBA")
        index = own_order.index(key)
        lookups[code] = {}
        for kind, offset, cw, ch, cols, rows, pad in (
            ("flagart", index, 192, 144, 5, 7, 2),
            ("flagcards", country_count + index, 256, 242, 4, 4, 8),
        ):
            page, cell = divmod(offset, cols * rows)
            page += 1
            col, row = cell % cols, cell // cols
            path = root / "assets/ui" / f"{kind}-{page}.png"
            if path not in pages:
                pages[path] = Image.open(path).convert("RGBA") if path.exists() else Image.new("RGBA", (cw * cols, ch * rows))
            atlas = pages[path]
            assert atlas.size == (cw * cols, ch * rows)
            # Same layout as flags.page_html: contain, centred, fixed padding.
            image = ImageOps.contain(flag, (cw - 2 * pad, ch - 2 * pad), Image.Resampling.LANCZOS)
            x, y = col * cw, row * ch
            atlas.paste((0, 0, 0, 0), (x, y, x + cw, y + ch))
            atlas.alpha_composite(image, (x + (cw - image.width) // 2, y + (ch - image.height) // 2))
            lookups[code][kind] = [page, col, row]
    for path, atlas in pages.items():
        atlas.save(path)
    print(json.dumps({"pages": [str(p.relative_to(root)) for p in pages], "lookups": lookups}, indent=2))


if __name__ == "__main__":
    import sys
    if sys.argv[1:] != ["--pack"]:
        raise SystemExit("Usage: python scripts/art/campaign_flags.py --pack")
    pack_pages()
