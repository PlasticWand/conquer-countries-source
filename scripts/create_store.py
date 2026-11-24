"""Create Conquest's Robux items through Open Cloud (Bruno gave autonomy over
names and prices on 2026-10-24; docs/design/store-items.md records them).

Usage, from the project root:
    python scripts/create_store.py all | <key> [<key> ...]

The items are read from src/shared/Store/Catalog.luau (PRODUCTS), so the game
and the store never disagree. Each gets a 512x512 icon drawn from the UI icon
atlas (assets/store/<key>.png). Reads the API key from the user environment
variable ROBLOX_API_KEY (never printed). Skips items whose name already
exists, so it is safe to rerun. Writes src/shared/Store/Products.luau
(key -> Roblox id) and prints {key: id}.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
import winreg
from pathlib import Path

from PIL import Image, ImageDraw

UNIVERSE = 10772018194  # Conquest
ROOT = Path(__file__).resolve().parents[1]
BASE = "https://apis.roblox.com"
LIST = {
    "pass": f"{BASE}/game-passes/v1/universes/{UNIVERSE}/game-passes/creator?pageSize=100",
    "product": f"{BASE}/developer-products/v2/universes/{UNIVERSE}/developer-products/creator?pageSize=100",
}
CREATE = {
    "pass": f"{BASE}/game-passes/v1/universes/{UNIVERSE}/game-passes",
    "product": f"{BASE}/developer-products/v2/universes/{UNIVERSE}/developer-products",
}
# key -> (atlas icon, background colour)
ICONS = {
    "crate1": ("chest", (255, 181, 52)),
    "crate3": ("chest", (255, 181, 52)),
    "crate5": ("chest", (255, 181, 52)),
    # In-match boosts (2026-11-23).
    "warChest": ("gold", (227, 181, 76)),
    "rearm": ("reload", (46, 138, 62)),
    "secondSpawn": ("flag", (185, 54, 51)),
    "starBoost": ("star", (255, 201, 60)),
    # The Campaign Pass premium (2026-11-23).
    "campaignPass": ("crown", (46, 94, 158)),
    # Gifts (2026-11-23).
    "giftCrate3": ("gift", (185, 54, 51)),
    "giftCrate5": ("gift", (185, 54, 51)),
    "giftPass": ("gift", (46, 94, 158)),
    "crateFirst": ("gift", (46, 163, 91)),
    "flagRare": ("flag", (79, 141, 255)),
    "flagEpic": ("flag", (176, 92, 255)),
    "flagLegendary": ("flag", (255, 181, 52)),
    "unlockReinforce": ("troops", (30, 40, 64)),
    "unlockMega": ("atom", (185, 54, 51)),
    "unlockArtillery": ("defense", (122, 92, 40)),
    "unlockScatter": ("mirv", (130, 60, 170)),
    "unlockAirStrike": ("explosion", (47, 94, 158)),
    "unlockRailgun": ("bolt", (60, 64, 76)),
    "unlockRapidReload": ("reload", (46, 138, 62)),
    "unlockParatroopers": ("troops", (78, 98, 52)),
    "unlockCoastal": ("port", (40, 84, 120)),
    "unlockSabotage": ("explosion", (90, 40, 40)),
    "unlockFieldWorks": ("defense", (110, 90, 50)),
    "takeover": ("crown", (185, 54, 51)),
    "starterPack": ("gift", (46, 163, 91)),
    "doubleStars": ("star", (255, 201, 60)),
    # Star packs (2026-11-16).
    "stars10k": ("star", (255, 201, 60)),
    "stars35k": ("star", (255, 201, 60)),
    "stars100k": ("star", (255, 201, 60)),
    "stars300k": ("star", (255, 201, 60)),
}
# Daily deals (2026-11-16) wear their weapon's icon.
for _key in [k for k in ICONS if k.startswith("unlock")]:
    ICONS["deal" + _key[len("unlock"):]] = ICONS[_key]

with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as env:
    KEY = winreg.QueryValueEx(env, "ROBLOX_API_KEY")[0]


def catalog_products():
    text = (ROOT / "src" / "shared" / "Store" / "Catalog.luau").read_text(encoding="utf-8")
    block = text[text.index("Catalog.PRODUCTS = {"):]
    block = block[:block.index("} :: { Product }")]
    items = {}
    for m in re.finditer(r'\{ key = "(\w+)", kind = "(\w+)", name = "([^"]+)", price = (\d+), desc = "([^"]+)" \}', block):
        key, kind, name, price, desc = m.groups()
        items[key] = (kind, name, int(price), desc)
    return items


def icon(key: str) -> Path:
    atlas = Image.open(ROOT / "assets" / "ui" / "icon-atlas.png").convert("RGBA")
    cells = {}
    for line in (ROOT / "src" / "client" / "Ui" / "IconAtlas.luau").read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*(\w+) = \{ (\d+), (\d+) \},", line)
        if m:
            cells[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    name, colour = ICONS[key]
    col, row = cells[name]
    mask = atlas.crop((col * 96, row * 96, col * 96 + 96, row * 96 + 96)).getchannel("A").resize((320, 320), Image.LANCZOS)
    img = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle((16, 16, 496, 496), radius=96, fill=colour + (255,))
    dark = tuple(max(0, c - 60) for c in colour)
    draw.rounded_rectangle((16, 16, 496, 496), radius=96, outline=dark + (255,), width=12)
    glyph_colour = (28, 20, 5, 255) if sum(colour) > 450 else (255, 255, 255, 255)
    glyph = Image.new("RGBA", (320, 320), glyph_colour)
    img.paste(glyph, (96, 96), mask)
    out = ROOT / "assets" / "store" / f"{key}.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    return out


def call(method, url, body=None, content_type=None):
    req = urllib.request.Request(url, data=body, method=method, headers={"x-api-key": KEY})
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def existing(kind):
    status, body = call("GET", LIST[kind])
    if status != 200:
        sys.exit(f"listing {kind}s failed: HTTP {status} {body[:300]}")
    data = json.loads(body)
    rows = data.get("gamePasses") if kind == "pass" else data.get("developerProducts")
    return {row.get("name"): row.get("gamePassId") or row.get("productId") or row.get("id") for row in rows or []}


def multipart(fields, icon_path):
    boundary = uuid.uuid4().hex
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items()]
    if icon_path:
        image = Path(icon_path).read_bytes()
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="imageFile"; filename="{Path(icon_path).name}"\r\n'
                     "Content-Type: image/png\r\n\r\n".encode() + image + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def write_products(ids):
    path = ROOT / "src" / "shared" / "Store" / "Products.luau"
    known = {}
    if path.exists():
        for m in re.finditer(r"(\w+) = (\d+),", path.read_text(encoding="utf-8")):
            known[m.group(1)] = int(m.group(2))
    known.update({k: int(v) for k, v in ids.items() if v})
    lines = ["--!strict", "-- Generated by scripts/create_store.py: Roblox ids of the store's",
             "-- developer products and game passes (Store/Catalog.PRODUCTS keys).", "return {"]
    for k in sorted(known):
        lines.append(f"\t{k} = {known[k]},")
    lines += ["}", ""]
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def sync_prices(apply: bool):
    """Make live developer-product prices match Catalog.PRODUCTS. Run with
    --apply only once the build showing those prices is published: Roblox's
    prompt charges the live price at once, whatever the old build displays."""
    items = catalog_products()
    ids = {}
    for m in re.finditer(r"(\w+) = (\d+),", (ROOT / "src" / "shared" / "Store" / "Products.luau").read_text(encoding="utf-8")):
        ids[m.group(1)] = int(m.group(2))
    status, body = call("GET", LIST["product"])
    if status != 200:
        sys.exit(f"listing products failed: HTTP {status} {body[:300]}")
    live = {row["productId"]: row for row in json.loads(body)["developerProducts"]}
    changes = []
    for key, (kind, name, price, description) in items.items():
        if kind != "product" or key not in ids or ids[key] not in live:
            continue
        now = live[ids[key]]["priceInformation"]["defaultPriceInRobux"]
        if now != price:
            changes.append((key, ids[key], now, price))
    for key, pid, old, new in changes:
        line = f"{key}: {old} -> {new}"
        if apply:
            body, ctype = multipart({"price": str(new)}, None)
            status, text = call("PATCH", f"{CREATE['product']}/{pid}", body, ctype)
            line += f"  HTTP {status}" + ("" if status in (200, 204) else f" {text[:200]}")
        print(line)
    print(f"{len(changes)} price(s) differ" + ("" if apply else " (dry run; --apply to change them)"))


def main():
    if sys.argv[1:2] == ["sync"]:
        sync_prices("--apply" in sys.argv[2:])
        return
    items = catalog_products()
    wanted = list(items) if sys.argv[1:] == ["all"] else sys.argv[1:]
    unknown = [k for k in wanted if k not in items]
    if not wanted or unknown:
        sys.exit(f"usage: create_store.py all | {' '.join(items)}" + (f"\nunknown: {unknown}" if unknown else ""))
    have = {kind: existing(kind) for kind in ("pass", "product")}
    result = {}
    for key in wanted:
        kind, name, price, description = items[key]
        if name in have[kind]:
            result[key] = {"id": have[kind][name], "note": "already existed"}
            continue
        fields = {"name": name, "description": description, "price": str(price), "isForSale": "true", "isRegionalPricingEnabled": "true"}
        body, ctype = multipart(fields, icon(key) if key in ICONS else None)
        status, text = call("POST", CREATE[kind], body, ctype)
        try:
            data = json.loads(text)
        except ValueError:
            data = {}
        new_id = data.get("gamePassId") or data.get("productId") or data.get("id")
        result[key] = {"id": new_id, "status": status} if status == 200 else {"status": status, "error": text[:400]}
    write_products({k: v.get("id") for k, v in result.items()})
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
