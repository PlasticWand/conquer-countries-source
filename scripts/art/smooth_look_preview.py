"""Review exact Luau output; no image generation or runtime dependency."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
raw = ROOT / "capture/smooth-look"
out = ROOT / "art/ships"
atlas = Image.frombytes("RGBA", (516, 516), (raw / "ships.rgba").read_bytes())
sheet = Image.new("RGB", (900, 400), (47, 94, 120))
draw = ImageDraw.Draw(sheet)
font = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 20)
small = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 14)
draw.text((24, 18), "ORIGINAL SHIP MASKS  |  exact runtime art", font=font, fill="white")
for i, (label, color) in enumerate([
    ("TRANSPORT", (228, 176, 65)), ("TRADE SHIP", (73, 181, 174)), ("WARSHIP", (214, 114, 102))
]):
    x, y = i % 2 * 258 + 1, i // 2 * 258 + 1
    mask = atlas.crop((x, y, x + 256, y + 256))
    tinted = Image.merge("RGBA", tuple(mask.getchannel(c).point(lambda v, n=n: round(v * n / 255))
                                     for c, n in zip("RGB", color)) + (mask.getchannel("A"),))
    sheet.paste(tinted, (i * 300 + 22, 70), tinted)
    draw.text((i * 300 + 70, 340), label, font=font, fill="white")
    thumb = tinted.resize((39, 39), Image.Resampling.LANCZOS)
    sheet.paste(thumb, (i * 300 + 248, 292), thumb)
draw.text((24, 377), "Large: 256 px mask. Small: 13 tiles at zoom 3. Wake shares owner tint. No uploads needed.", font=small, fill="white")
sheet.save(out / "preview.png")

comparison = Image.new("RGB", (1072, 460), (33, 40, 43))
d = ImageDraw.Draw(comparison)
for i, name in enumerate(("source", "soft")):
    img = Image.frombytes("RGBA", (128, 96), (raw / f"{name}.rgba").read_bytes())
    img = img.resize((512, 384), Image.Resampling.NEAREST)
    comparison.paste(img, (16 + i * 528, 48), img)
    d.text((16 + i * 528, 14), "SOURCE" if name == "source" else "SOFT EDGES — PROTOTYPE, DEFAULT OFF", font=small, fill="white")
d.text((16, 440), "World crop; synthetic owners. Exact CPU raster output at 4x, not a Studio capture or curved-contour implementation.", font=small, fill="white")
comparison.save(out / "map-soft-prototype.png")
