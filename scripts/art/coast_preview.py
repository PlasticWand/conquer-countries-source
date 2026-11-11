"""Composite exact runtime coast patches above the unchanged source raster."""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "art/map"
OUT.mkdir(parents=True, exist_ok=True)
font = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 21)
small = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 15)
for mode in ("neutral", "owned", "neutral-2x", "owned-2x"):
    meta = json.loads((ROOT / f"capture/coasts/{mode}.json").read_text())
    c = meta["crop"]
    w, h, zoom = c["w"], c["h"], c["zoom"]
    before = Image.frombytes("RGBA", (w, h), (ROOT / f"capture/coasts/{mode}.rgba").read_bytes())
    before = before.resize((w * zoom, h * zoom), Image.Resampling.NEAREST)
    after = before.copy()
    for patch in meta["patches"]:
        size = 32 * c["resolution"]
        image = Image.frombytes("RGBA", (size, size), (ROOT / patch["path"]).read_bytes())
        image = image.resize((32 * zoom, 32 * zoom), Image.Resampling.BILINEAR)
        after.alpha_composite(image, (round((patch["x"] - c["x"]) * zoom), round((patch["y"] - c["y"]) * zoom)))
    sheet = Image.new("RGB", (w * zoom * 2 + 48, h * zoom + 112), (31, 39, 42))
    d = ImageDraw.Draw(sheet)
    sheet.paste(before, (16, 48)); sheet.paste(after, (w * zoom + 32, 48))
    d.text((16, 12), "BEFORE — 1 PIXEL / TILE", font=font, fill="white")
    d.text((w * zoom + 32, 12), f"AFTER — STATIC {c['resolution']}x COAST", font=font, fill="white")
    d.text((16, h * zoom + 62), "World coast at zoom 10. Tile picking unchanged. " + ("Synthetic ownership; territory boundaries stay stepped." if mode.startswith("owned") else "Land interiors keep source terrain pixels."), font=small, fill="white")
    d.text((16, h * zoom + 84), "CPU/native-property preview, not a Studio capture. Map credit OpenFront · CC BY-SA 4.0.", font=small, fill="white")
    sheet.save(OUT / f"coast-{mode}-before-after.png")
