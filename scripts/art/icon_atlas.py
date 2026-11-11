"""Build the UI icon atlas: one white-mask PNG with every screen icon in a grid.

Usage, from the project root:
    python scripts/art/icon_atlas.py [referenceRoot]

Sources:
  - OpenFront v0.35.2 resources/images (CC BY-SA 4.0, credit "OpenFront"):
    the game's own white icons, recoloured to white masks.
  - Our own simple icons, drawn here as inline SVG (menu, star, globe, chest...).
Writes assets/ui/icon-atlas.png and src/client/Ui/IconAtlas.luau (name -> cell).
Upload the PNG with scripts/upload_images.py and put its id in UiAssets.atlas.
The atlas is CC BY-SA 4.0 because it contains OpenFront's icons.
"""
import html
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render import render  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REF = Path(sys.argv[1] if len(sys.argv) > 1 else "../reference/openfront-v0.35.2")
IMAGES = REF / "resources" / "images"
CELL = 96
ICON = 80
COLS = 10

# Our own icons: 24x24 viewBox, white.
def own(body: str) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#fff" stroke="#fff">{body}</svg>'

OWN = {
    "menu": own('<rect x="3" y="5" width="18" height="2.6" rx="1.3" stroke="none"/><rect x="3" y="10.7" width="18" height="2.6" rx="1.3" stroke="none"/><rect x="3" y="16.4" width="18" height="2.6" rx="1.3" stroke="none"/>'),
    "star": own('<path stroke="none" d="M12 2.2l2.95 6.2 6.8.85-5 4.7 1.3 6.75L12 17.4l-6.05 3.3 1.3-6.75-5-4.7 6.8-.85z"/>'),
    "globe": own('<g fill="none" stroke-width="1.8"><circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3.5 9h17M3.5 15h17"/></g>'),
    "chest": own('<path stroke="none" d="M3 10h18v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 19z"/><path stroke="none" d="M4.5 4h15A1.5 1.5 0 0 1 21 5.5V9H3V5.5A1.5 1.5 0 0 1 4.5 4z" opacity=".75"/><rect x="10" y="8" width="4" height="5" rx="1" stroke="none"/>'),
    "bag": own('<path stroke="none" d="M5 8h14l-1.2 12.2a1.6 1.6 0 0 1-1.6 1.4H7.8a1.6 1.6 0 0 1-1.6-1.4z"/><path fill="none" stroke-width="1.9" d="M8.5 10V6.8a3.5 3.5 0 0 1 7 0V10"/>'),
    "lock": own('<rect x="5" y="10.5" width="14" height="10.5" rx="2" stroke="none"/><path fill="none" stroke-width="2.2" d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>'),
    "check": own('<path fill="none" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" d="M4.5 12.5l5 5 10-11"/>'),
    "chevronRight": own('<path fill="none" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round" d="M9 4.5l7.5 7.5L9 19.5"/>'),
    "chevronDown": own('<path fill="none" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round" d="M4.5 9l7.5 7.5L19.5 9"/>'),
    "clock": own('<g fill="none" stroke-width="2.2"><circle cx="12" cy="12" r="9"/><path stroke-linecap="round" d="M12 7v5.5l3.5 2"/></g>'),
    "close": own('<path fill="none" stroke-width="3" stroke-linecap="round" d="M5.5 5.5l13 13M18.5 5.5l-13 13"/>'),
    "play": own('<path stroke="none" d="M7 4.2v15.6a1 1 0 0 0 1.5.86l12.4-7.8a1 1 0 0 0 0-1.72L8.5 3.34A1 1 0 0 0 7 4.2z"/>'),
    "plus": own('<path fill="none" stroke-width="3" stroke-linecap="round" d="M12 5v14M5 12h14"/>'),
    "flag": own('<path stroke="none" d="M5 3h1.8v18H5z"/><path stroke="none" d="M7.5 4h11.5l-2.6 4.5L19 13H7.5z"/>'),
    "brush": own('<path stroke="none" d="M19.8 2.6a1.4 1.4 0 0 1 1.6 1.6c-.8 3.3-4.6 8.6-7.6 11l-2.9-2.9c2.3-3 7.6-6.9 8.9-9.7z"/><path stroke="none" d="M9.8 13.4l2.7 2.7c-.3 2.8-2.4 4.9-5.6 4.9H3.5c1.8-1.2 1.6-2.9 2.4-4.6.7-1.6 2.1-2.8 3.9-3z"/>'),
    "keyboard": own('<rect x="2" y="6" width="20" height="12" rx="2" fill="none" stroke-width="1.8"/><path stroke="none" d="M5 9h2v2H5zm3.5 0h2v2h-2zm3.5 0h2v2h-2zm3.5 0h2v2h-2zM5 12.5h2v2H5zm3.5 0h7v2h-7zm8.5 0h2v2h-2z"/>'),
    "hand": own('<path stroke="none" d="M9 3.5a1.5 1.5 0 0 1 3 0V11l.6-.1V5a1.5 1.5 0 0 1 3 0v6.3l.5.1V7a1.5 1.5 0 0 1 3 0v7.5c0 4.4-3 7.5-7.2 7.5-2.5 0-4.4-1.2-5.8-3.3L3.4 14c-.7-1.1.5-2.4 1.6-1.7L9 14.7z"/>'),
    "sound": own('<path stroke="none" d="M3 9h4l5-4.5v15L7 15H3z"/><path fill="none" stroke-width="2" stroke-linecap="round" d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>'),
    "eye": own('<mask id="m"><rect width="24" height="24" fill="#fff"/><circle cx="12" cy="12" r="3.4" fill="#000"/></mask><path mask="url(#m)" stroke="none" d="M12 5C6.5 5 2.7 9.4 1.6 12c1.1 2.6 4.9 7 10.4 7s9.3-4.4 10.4-7C21.3 9.4 17.5 5 12 5z"/><circle cx="12" cy="12" r="1.6" stroke="none"/>'),
    "bolt": own('<path stroke="none" d="M13.5 2L4.5 13.5h6.2L9.5 22l9-11.5h-6.2z"/>'),
    "reload": own('<path fill="none" stroke-width="2.4" stroke-linecap="round" d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3"/><path stroke="none" d="M20.5 3.5v6.5H14z"/>'),
    "surrender": own('<path stroke="none" d="M5 3h1.8v18H5z"/><path stroke="none" d="M7.5 4h12v9h-12z"/>'),
    "question": own('<text x="12" y="20" text-anchor="middle" font-family="Arial Black, Arial, sans-serif" font-weight="900" font-size="22" stroke="none">?</text>'),
    "retreat": own('<path fill="none" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" d="M9.5 5.5L4 11l5.5 5.5"/><path fill="none" stroke-width="2.6" stroke-linecap="round" d="M4.5 11h9a6 6 0 0 1 0 12h-2" transform="translate(0 -3)"/>'),
    "gift": own('<rect x="3" y="9" width="18" height="4" rx="1" stroke="none"/><rect x="4.5" y="13" width="15" height="8" rx="1" stroke="none"/><path stroke="none" d="M11 9h2v12h-2z" fill="#000" opacity=".5"/><path fill="none" stroke-width="1.8" d="M12 9c-1-3.5-5-4.5-5.5-2.5S9 9 12 9c3 0 6-.5 5.5-2.5S13 5.5 12 9z"/>'),
    "skull": own('<mask id="m"><rect width="24" height="24" fill="#fff"/><circle cx="8.8" cy="11" r="2.1" fill="#000"/><circle cx="15.2" cy="11" r="2.1" fill="#000"/><path d="M11 14.5h2l-1 1.8z" fill="#000"/></mask><path mask="url(#m)" stroke="none" d="M12 2.5c-4.7 0-8 3.3-8 7.7 0 2.6 1.2 4.4 2.8 5.4V19a1 1 0 0 0 1 1h1.4v-2h1.6v2h2.4v-2h1.6v2h1.4a1 1 0 0 0 1-1v-3.4c1.6-1 2.8-2.8 2.8-5.4 0-4.4-3.3-7.7-8-7.7z"/>'),
}

# name -> OpenFront file in resources/images
OPENFRONT = {
    "settings": "SettingIconWhite.svg",
    "help": "QuestionMarkIcon.svg",
    "music": "music.svg",
    "chat": "ChatIconWhite.svg",
    "leaderboard": "LeaderboardIconSolidWhite.svg",
    "exit": "ExitIconWhite.svg",
    "party": "TeamIconSolidWhite.svg",
    "pause": "PauseIconWhite.svg",
    "crown": "CrownIcon.svg",
    "shield": "ShieldIconWhite.svg",
    "sword": "SwordIconWhite.svg",
    "troops": "TroopIconWhite.svg",
    "gold": "GoldCoinIcon.svg",
    "city": "CityIconWhite.svg",
    "port": "TradingIconWhite.svg",
    "factory": "FactoryIconWhite.svg",
    "defense": "ShieldIconWhite.svg",
    "sam": "SamLauncherIconWhite.svg",
    "silo": "MissileSiloIconWhite.svg",
    "warship": "BattleshipIconWhite.svg",
    "atom": "NukeIconWhite.svg",
    "hydrogen": "MushroomCloudIconWhite.svg",
    "mirv": "MIRVIcon.svg",
    "boat": "BoatIconWhite.svg",
    "trade": "TradeShipIconWhite.svg",
    "target": "TargetIconWhite.svg",
    "alliance": "AllianceIconWhite.svg",
    "allianceRequest": "AllianceRequestWhiteIcon.svg",
    "traitor": "TraitorIconWhite.svg",
    "emoji": "EmojiIconWhite.svg",
    "info": "InfoIconSolidWhite.svg",
    "donateGold": "DonateGoldIconWhite.svg",
    "donateTroops": "DonateTroopIconWhite.svg",
    "embargo": "EmbargoWhiteIcon.svg",
    "mouse": "MouseIconWhite.svg",
    "population": "PopulationIconSolidWhite.svg",
    "siren": "SirenIconWhite.svg",
    "explosion": "ExplosionIconWhite.svg",
    "focus": "FocusIconWhite.svg",
    "fastForward": "FastForwardIconSolidWhite.svg",
    "build": "BuildIconWhite.svg",
    "disconnected": "DisconnectedIcon.svg",
    "medal": "MedalIconWhite.svg",
}


def main() -> None:
    names = list(OPENFRONT) + list(OWN)
    rows = (len(names) + COLS - 1) // COLS
    width, height = COLS * CELL, rows * CELL
    cells = []
    mapping = {}
    for i, name in enumerate(names):
        col, row = i % COLS, i // COLS
        mapping[name] = (col, row)
        if name in OPENFRONT:
            src = (IMAGES / OPENFRONT[name]).as_uri()
        else:
            src = "data:image/svg+xml;utf8," + html.escape(OWN[name].replace("#", "%23"), quote=True)
        pad = (CELL - ICON) // 2
        cells.append(
            f'<img src="{src}" style="position:absolute;left:{col * CELL + pad}px;top:{row * CELL + pad}px;'
            f'width:{ICON}px;height:{ICON}px;object-fit:contain;filter:brightness(0) invert(1)">'
        )
    page = ROOT / "assets" / "ui" / "icon-atlas.html"
    page.write_text(
        f'<!doctype html><html><body style="margin:0;background:transparent;width:{width}px;height:{height}px;'
        f'position:relative;overflow:hidden">{"".join(cells)}</body></html>',
        encoding="utf-8",
    )
    out = ROOT / "assets" / "ui" / "icon-atlas.png"
    render(page, out, width, height, transparent=True)
    page.unlink()
    img = Image.open(out).convert("RGBA")
    assert img.size == (width, height), img.size
    empty = []
    for name, (col, row) in mapping.items():
        box = img.crop((col * CELL, row * CELL, (col + 1) * CELL, (row + 1) * CELL))
        if box.getchannel("A").getextrema()[1] == 0:
            empty.append(name)
    # White masks: force RGB to white, keep alpha.
    alpha = img.getchannel("A")
    white = Image.new("RGBA", img.size, (255, 255, 255, 0))
    white.putalpha(alpha)
    white.save(out)
    lines = [
        "--!strict",
        "-- Generated by scripts/art/icon_atlas.py. Do not edit; regenerate.",
        "-- Cells of assets/ui/icon-atlas.png (white masks; tint with ImageColor3).",
        "-- Contains OpenFront v0.35.2 icons: CC BY-SA 4.0, credit \"OpenFront\".",
        "return {",
        f"\tcell = {CELL},",
        "\ticons = {",
    ]
    for name, (col, row) in mapping.items():
        lines.append(f"\t\t{name} = {{ {col}, {row} }},")
    lines += ["\t},", "}", ""]
    (ROOT / "src" / "client" / "Ui" / "IconAtlas.luau").write_text("\n".join(lines), encoding="utf-8")
    print(f"atlas {width}x{height}, {len(names)} icons", "EMPTY: " + ", ".join(empty) if empty else "all cells drawn")


if __name__ == "__main__":
    main()
