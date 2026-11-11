"""Flags for the Locker and the Flag Shop.

Usage, from the project root:
    python scripts/art/flags.py [referenceRoot]

1. Country flags: OpenFront v0.35.2 resources/flags/<code>.svg for every
   two-letter code in resources/countries.json (CC BY-SA 4.0, credit
   "OpenFront"), as waving cloth where art/flags-cloth/flags/<code>.png exists
   (Codex's redraw of that SVG, same licence), packed 96x72 into pages assets/ui/flags-<n>.png (10x14 cells).
2. Our own flags (original art, drawn below as SVG; as waving cloth where
   art/flags-cloth/flags/o_<key>.png exists): the Halloween set and the
   daily-rotation pool, 192x144 each, packed into assets/ui/flagart-<n>.png
   (5x7 cells).
Writes src/shared/Store/FlagList.luau (ids, names, rarities, sets) and
src/client/Ui/FlagArt.luau (where each flag's picture is). Upload the pages
with scripts/upload_images.py --openfront and put the ids in FlagArt.PAGES.
"""
import hashlib
import html
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render import render  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REF = Path(sys.argv[1] if len(sys.argv) > 1 else "../reference/openfront-v0.35.2")
OUT = ROOT / "assets" / "ui"
CARD_W, CARD_H, CARD_PAD = 256, 242, 8  # a crate card's picture window is 1.06 : 1
CLOTH = ROOT / "art" / "flags-cloth" / "flags"

# Our own flags, viewBox 0 0 160 120.
def svg(body: str) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 120">{body}</svg>'

BAT = "M0 0c4-6 10-8 14-4 1-4 4-5 6-5 2 0 5 1 6 5 4-4 10-2 14 4-5-2-9 0-11 4-2-2-5-2-7 0-2-2-5-2-7 0-2-4-6-6-11-4z"
OWN = {
    # Halloween: limited event set.
    "harvest_lantern": ("Harvest Lantern", "legendary", "halloween", svg(
        '<rect width="160" height="120" fill="#1d3b2a"/><path d="M0 120L160 0v34L44 120z" fill="#e8742a"/>'
        '<rect x="66" y="22" width="28" height="8" rx="3" fill="#2b2b2b"/><path d="M80 14v8" stroke="#2b2b2b" stroke-width="4"/>'
        '<rect x="58" y="30" width="44" height="58" rx="10" fill="#ffcf4a" stroke="#2b2b2b" stroke-width="5"/>'
        '<path d="M80 40c-8 10-8 20 0 30 8-10 8-20 0-30z" fill="#ff7a1a"/><rect x="62" y="88" width="36" height="8" rx="3" fill="#2b2b2b"/>')),
    "midnight_flight": ("Midnight Flight", "epic", "halloween", svg(
        '<rect width="160" height="120" fill="#2a1446"/><circle cx="104" cy="50" r="34" fill="#f3e6b0"/><circle cx="118" cy="42" r="30" fill="#2a1446"/>'
        f'<g fill="#0d0716"><path transform="translate(24 30) scale(1.4)" d="{BAT}"/><path transform="translate(70 70) scale(1.1)" d="{BAT}"/><path transform="translate(40 86) scale(.8)" d="{BAT}"/></g>')),
    "bone_banner": ("Bone Banner", "epic", "halloween", svg(
        '<rect width="160" height="120" fill="#111"/><path d="M0 0l80 46L160 0v16L80 62 0 16z" fill="#e9e2cf"/>'
        '<g stroke="#e9e2cf" stroke-width="9" stroke-linecap="round"><path d="M52 66l56 40M108 66l-56 40"/></g>'
        '<g fill="#e9e2cf"><circle cx="48" cy="62" r="7"/><circle cx="112" cy="62" r="7"/><circle cx="48" cy="110" r="7"/><circle cx="112" cy="110" r="7"/></g>')),
    "raven_watch": ("Raven Watch", "rare", "halloween", svg(
        '<rect width="160" height="120" fill="#8e1c1c"/><rect y="84" width="160" height="36" fill="#3a0b0b"/>'
        '<path d="M50 84c0-22 14-40 34-42l8-10 6 9c10 2 16 10 16 20l14 6-14 2c-2 10-8 15-16 15z" fill="#0b0b0b"/>'
        '<circle cx="98" cy="48" r="3" fill="#ffd34a"/><path d="M60 84h40l-4 10H64z" fill="#0b0b0b"/>')),
    "wisp_lights": ("Wisp Lights", "rare", "halloween", svg(
        '<rect width="160" height="120" fill="#0f2b2e"/><g fill="#6ff2d8" opacity=".9">'
        '<path d="M40 70c-10 0-14-12-6-20 2 6 6 6 8 2 8 6 8 18-2 18z"/><path d="M84 52c-12 0-16-14-7-24 2 7 7 7 9 2 10 8 9 22-2 22z"/>'
        '<path d="M124 78c-9 0-12-10-5-17 2 5 5 5 7 1 7 6 7 16-2 16z"/></g>'
        '<path d="M0 100c30-10 50 8 80 0s50-10 80 0v20H0z" fill="#082022"/>')),
    "haunted_manor": ("Haunted Manor", "epic", "halloween", svg(
        '<rect width="160" height="120" fill="#3b2a5c"/><circle cx="124" cy="28" r="14" fill="#fff4c2"/>'
        '<path d="M30 112V60l26-22 26 22v-14h12v24l12-10 24 20v32z" fill="#151020"/>'
        '<g fill="#ffcf4a"><rect x="44" y="70" width="8" height="10"/><rect x="62" y="70" width="8" height="10"/><rect x="108" y="84" width="8" height="10"/><rect x="52" y="92" width="10" height="20"/></g>')),
    # The daily rotation pool.
    "compass_rose": ("Compass Rose", "rare", "daily", svg(
        '<rect width="160" height="120" fill="#1b4f72"/><g transform="translate(80 60)">'
        '<path d="M0-48l8 40 40 8-40 8-8 40-8-40-40-8 40-8z" fill="#f4f1e6"/><path d="M0-48l8 40H-8z" fill="#e2483d"/>'
        '<circle r="6" fill="#1b4f72"/></g>')),
    "thunder_peak": ("Thunder Peak", "epic", "daily", svg(
        '<rect width="160" height="120" fill="#2c3e8f"/><path d="M0 120l52-64 24 26 22-40 62 78z" fill="#e8ecf5"/>'
        '<path d="M96 8L74 52h16l-12 34 32-46H94l14-32z" fill="#ffd23f"/>')),
    "crossed_sabers": ("Crossed Sabers", "rare", "daily", svg(
        '<rect width="160" height="120" fill="#6b1d2a"/><rect y="48" width="160" height="24" fill="#d9b44a"/>'
        '<g stroke="#f2f2f2" stroke-width="7" stroke-linecap="round" fill="none"><path d="M40 100C70 70 96 40 124 18"/><path d="M120 100C90 70 64 40 36 18"/></g>'
        '<g fill="#d9b44a"><rect x="30" y="94" width="18" height="8" rx="3"/><rect x="112" y="94" width="18" height="8" rx="3"/></g>')),
    "comet_trail": ("Comet Trail", "epic", "daily", svg(
        '<rect width="160" height="120" fill="#0e1430"/><path d="M14 104L104 38l10 14z" fill="#5fd0ff" opacity=".5"/>'
        '<path d="M30 110L108 44l6 8z" fill="#c9f1ff" opacity=".6"/><circle cx="114" cy="40" r="16" fill="#fff6d5"/>'
        '<g fill="#fff"><circle cx="30" cy="22" r="2"/><circle cx="60" cy="14" r="1.5"/><circle cx="140" cy="96" r="2"/><circle cx="146" cy="16" r="1.5"/></g>')),
    "polar_star": ("Polar Star", "common", "daily", svg(
        '<rect width="160" height="120" fill="#0b6e4f"/><rect x="58" width="44" height="120" fill="#f5f5f5"/>'
        '<path d="M80 26l7 20 21 0-17 12 7 21-18-13-18 13 7-21-17-12h21z" fill="#0b6e4f"/>')),
    "old_oak": ("Old Oak", "common", "daily", svg(
        '<rect width="160" height="120" fill="#e9dfc4"/><rect x="72" y="62" width="16" height="44" fill="#6b4a2b"/>'
        '<g fill="#3f7d3a"><circle cx="80" cy="44" r="28"/><circle cx="56" cy="56" r="18"/><circle cx="104" cy="56" r="18"/></g>'
        '<rect y="104" width="160" height="16" fill="#3f7d3a"/>')),
    "sky_rocket": ("Sky Rocket", "epic", "daily", svg(
        '<rect width="160" height="120" fill="#3a1d6e"/><g transform="rotate(35 80 60)">'
        '<path d="M80 8c14 14 18 40 12 66H68C62 48 66 22 80 8z" fill="#f4f4f8"/><circle cx="80" cy="40" r="8" fill="#4cc4f0"/>'
        '<path d="M68 60l-12 24 14-6zM92 60l12 24-14-6z" fill="#e2483d"/><path d="M72 76h16l-8 26z" fill="#ffb534"/></g>')),
    "fire_mountain": ("Fire Mountain", "rare", "daily", svg(
        '<rect width="160" height="120" fill="#2a2a2a"/><path d="M20 120l44-70h32l44 70z" fill="#5a4636"/>'
        '<path d="M64 50h32l-6 16-10-8-10 10z" fill="#ff5b2e"/><g fill="#ff8a2e"><circle cx="72" cy="30" r="8"/><circle cx="88" cy="22" r="10"/><circle cx="80" cy="38" r="7"/></g>')),
    "great_wave": ("Great Wave", "rare", "daily", svg(
        '<rect width="160" height="120" fill="#f1ead8"/>'
        '<path d="M0 120V80c20-30 50-50 84-40 22 6 30 26 18 36-6-14-22-18-30-8 16 4 22 16 14 26 30 4 50-8 74-26v52z" fill="#1d5b8f"/>'
        '<path d="M84 40c22 6 30 26 18 36-6-14-22-18-30-8" fill="none" stroke="#f1ead8" stroke-width="4"/>')),
    "iron_anchor": ("Iron Anchor", "common", "daily", svg(
        '<rect width="160" height="120" fill="#123a5a"/><rect y="0" width="160" height="12" fill="#d8d8d8"/><rect y="108" width="160" height="12" fill="#d8d8d8"/>'
        '<g fill="none" stroke="#f0f0f0" stroke-width="8" stroke-linecap="round"><circle cx="80" cy="30" r="8"/><path d="M80 38v58"/><path d="M60 52h40"/><path d="M48 76c4 18 18 24 32 24s28-6 32-24"/></g>')),
    "laurel_crown": ("Laurel Crown", "legendary", "daily", svg(
        '<rect width="160" height="120" fill="#5b1f6b"/><path d="M50 72l6-36 14 18 10-24 10 24 14-18 6 36z" fill="#ffc93c"/>'
        '<rect x="50" y="72" width="60" height="10" fill="#ffc93c"/><g fill="none" stroke="#7bd389" stroke-width="5">'
        '<path d="M40 40c-8 20-4 46 20 60"/><path d="M120 40c8 20 4 46-20 60"/></g>')),
    "night_owl": ("Night Owl", "rare", "daily", svg(
        '<rect width="160" height="120" fill="#24324a"/><ellipse cx="80" cy="70" rx="34" ry="40" fill="#8a6a4a"/>'
        '<path d="M50 34l12 12M110 34l-12 12" stroke="#8a6a4a" stroke-width="8"/><g fill="#f6e7a8"><circle cx="66" cy="58" r="12"/><circle cx="94" cy="58" r="12"/></g>'
        '<g fill="#1a1a1a"><circle cx="66" cy="58" r="5"/><circle cx="94" cy="58" r="5"/></g><path d="M74 70h12l-6 10z" fill="#ffb534"/>')),
}

# The daily pool's second batch (Bruno, 2026-11-11: 60 daily flags): 48 more
# originals in daily_flags.py, after the first 18 so their cells don't move.
from daily_flags import DAILY_NEW  # noqa: E402
# Then the Thanksgiving set (Bruno, 2026-11-11), a limited yearly event.
from event_flags import THANKSGIVING  # noqa: E402

FIRST_BATCH = len(OWN)
for _batch in (DAILY_NEW, THANKSGIVING):
    for _key, (_name, _rarity, _group, _body) in _batch.items():
        assert _key not in OWN, _key
        OWN[_key] = (_name, _rarity, _group, svg(_body))

RARITY_SHARE = [("common", 70), ("rare", 22), ("epic", 6), ("legendary", 2)]


def country_rarity(code: str) -> str:
    h = int(hashlib.sha1(code.encode()).hexdigest(), 16) % 100
    for rarity, share in RARITY_SHARE:
        if h < share:
            return rarity
        h -= share
    return "common"


def page_html(cells, cw, ch, cols, rows, pad=2) -> str:
    imgs = []
    for i, src in enumerate(cells):
        col, row = i % cols, i // cols
        # An SVG flag fills its cell (cover trims its square canvas); a cloth
        # flag keeps its waving outline whole (contain).
        fit = "contain" if src.endswith(".png") else "cover"
        imgs.append(f'<img src="{src}" style="position:absolute;left:{col * cw + pad}px;top:{row * ch + pad}px;'
                    f'width:{cw - 2 * pad}px;height:{ch - 2 * pad}px;object-fit:{fit}">')
    return (f'<!doctype html><html><body style="margin:0;background:transparent;width:{cols * cw}px;'
            f'height:{rows * ch}px;position:relative;overflow:hidden">{"".join(imgs)}</body></html>')


def pack(name: str, sources, cw: int, ch: int, cols: int, rows: int, pad: int = 2):
    per = cols * rows
    where = {}
    pages = 0
    for start in range(0, len(sources), per):
        pages += 1
        chunk = sources[start:start + per]
        page = OUT / f"{name}-{pages}.html"
        page.write_text(page_html([s for _, s in chunk], cw, ch, cols, rows, pad), encoding="utf-8")
        render(page, OUT / f"{name}-{pages}.png", cols * cw, rows * ch, transparent=True)
        page.unlink()
        for i, (key, _) in enumerate(chunk):
            where[key] = (pages, i % cols, i // cols)
    return where, pages


def country_source(code: str) -> str:
    """The cloth flag (art/flags-cloth/flags, Bruno 2026-11-02: Codex's style D)
    where there is one, else OpenFront's flat SVG."""
    cloth = CLOTH / f"{code}.png"
    return cloth.as_uri() if cloth.exists() else (REF / "resources" / "flags" / f"{code}.svg").as_uri()


def main() -> None:
    countries = json.load(open(REF / "resources" / "countries.json", encoding="utf-8"))
    flags = []
    for c in countries:
        code = c["code"]
        if re.fullmatch(r"[a-z]{2}", code) and (REF / "resources" / "flags" / f"{code}.svg").exists():
            flags.append((code, c["name"]))
    flags.sort(key=lambda f: f[1])
    country_cells, country_pages = pack("flags", [(f"f_{code}", country_source(code)) for code, _ in flags], 96, 72, 10, 14)
    own_sources = []
    for key, (_, _, _, body) in OWN.items():
        cloth = CLOTH / f"o_{key}.png"
        own_sources.append((f"o_{key}", cloth.as_uri() if cloth.exists() else "data:image/svg+xml;utf8," + html.escape(body.replace("#", "%23"), quote=True)))
    own_cells, own_pages = pack("flagart", own_sources, 192, 144, 5, 7)
    # Crate cards (Bruno, 2026-11-02: "pixelated"): every flag big and whole,
    # centred in a cell the shape of the card's picture window (CARD_LAYOUT in
    # Ui/Crate/CrateOpening), so a crop to the window shows all of it.
    card_sources = [(f"f_{code}", country_source(code)) for code, _ in flags] + own_sources
    card_cells, card_pages = pack("flagcards", card_sources, CARD_W, CARD_H, 4, 4, CARD_PAD)

    lines = [
        "--!strict",
        "-- Generated by scripts/art/flags.py. Do not edit; regenerate.",
        "-- Country flags: OpenFront v0.35.2 resources (CC BY-SA 4.0, credit \"OpenFront\").",
        "-- Own flags (o_*): original Conquest art. `set`: \"country\", \"halloween\" (limited) or \"daily\".",
        "return {",
    ]
    for code, name in flags:
        lines.append(f'\t{{ id = "f_{code}", name = {json.dumps(name, ensure_ascii=False)}, rarity = "{country_rarity(code)}", set = "country" }},')
    for key, (name, rarity, group, _) in OWN.items():
        lines.append(f'\t{{ id = "o_{key}", name = {json.dumps(name)}, rarity = "{rarity}", set = "{group}" }},')
    lines += ["}", ""]
    (ROOT / "src" / "shared" / "Store" / "FlagList.luau").write_text("\n".join(lines), encoding="utf-8", newline="\n")

    art = ROOT / "src" / "client" / "Ui" / "FlagArt.luau"
    old = art.read_text(encoding="utf-8") if art.exists() else ""
    old_country = re.findall(r'COUNTRY_PAGES = \{([^}]*)\}', old)
    old_own = re.findall(r'OWN_PAGES = \{([^}]*)\}', old)
    old_card = re.findall(r'CARD_PAGES = \{([^}]*)\}', old)
    def ids(found, n):
        got = re.findall(r'"(rbxassetid://\d+)"', found[0]) if found else []
        return ", ".join(f'"{got[i]}"' if i < len(got) else '""' for i in range(n))
    out = [
        "--!strict",
        "-- Generated by scripts/art/flags.py; the page ids are kept across",
        "-- regenerations (re-upload changed pages). Country flags are OpenFront's",
        "-- (CC BY-SA 4.0); o_* flags are original Conquest art.",
        "return {",
        "\tcountry = { w = 96, h = 72 },",
        "\town = { w = 192, h = 144 },",
        f"\tcard = {{ w = {CARD_W}, h = {CARD_H}, pageW = {4 * CARD_W}, pageH = {4 * CARD_H} }},",
        f"\tCOUNTRY_PAGES = {{ {ids(old_country, country_pages)} }},",
        f"\tOWN_PAGES = {{ {ids(old_own, own_pages)} }},",
        f"\tCARD_PAGES = {{ {ids(old_card, card_pages)} }},",
        "\tcells = {",
    ]
    for key, (page, col, row) in {**country_cells, **own_cells}.items():
        out.append(f'\t\t["{key}"] = {{ {page}, {col}, {row} }},')
    out += ["\t},", "\t-- The crate cards' big pictures: page, column and row of a whole cell.", "\tcardCells = {"]
    for key, (page, col, row) in card_cells.items():
        out.append(f'\t\t["{key}"] = {{ {page}, {col}, {row} }},')
    out += ["\t},", "}", ""]
    art.write_text("\n".join(out), encoding="utf-8", newline="\n")
    print(f"{len(flags)} country flags on {country_pages} page(s); {len(OWN)} own flags on {own_pages} page(s); crate cards on {card_pages} page(s)")


if __name__ == "__main__":
    main()
