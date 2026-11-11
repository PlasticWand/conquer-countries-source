"""Three review mockups over the renderer's World headless preview.

The preview is produced by `lune run tests/OpenFrontRasterPreview`. The
result is a design comparison, not a Studio capture or a shipped palette.
OpenFront resources/ map data in the preview is CC BY-SA 4.0; credit OpenFront.
"""
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, PngImagePlugin

source = Path(tempfile.gettempdir()) / 'ConquestOpenFrontPreview-political.png'
assert source.exists(), 'Run lune run tests/OpenFrontRasterPreview first'
world = Image.open(source).convert('RGB')
box = (100, 65, 700, 465)
crop = world.crop(box)
# Preview player 1 is the United States spawn and the Core's local player.
cx, cy, radius = 484 - box[0], 284 - box[1], 35
cards = []
title_font = ImageFont.truetype('C:/Windows/Fonts/arialbd.ttf', 22)
note_font = ImageFont.truetype('C:/Windows/Fonts/arial.ttf', 16)
titles = [
    ('A  Source palette', 'Current fill and focused border'),
    ('B  Contrast rim', 'Same fill; gold-and-ink selection ring'),
    ('C  Brighter own fill', 'Saturated cyan-blue fill and dark rim'),
]
for index, (title, subtitle) in enumerate(titles):
    panel = Image.new('RGB', (620, 475), (27, 34, 44))
    scene = crop.copy()
    draw = ImageDraw.Draw(scene)
    if index == 1:
        draw.ellipse((cx-radius-3, cy-radius-3, cx+radius+3, cy+radius+3), outline=(16, 27, 37), width=5)
        draw.ellipse((cx-radius, cy-radius, cx+radius, cy+radius), outline=(255, 219, 45), width=3)
    if index == 2:
        pix = scene.load()
        for y in range(cy-radius+2, cy+radius-1):
            for x in range(cx-radius+2, cx+radius-1):
                if (x-cx)**2 + (y-cy)**2 <= (radius-2)**2:
                    old = pix[x, y]
                    pix[x, y] = tuple(round(old[j]*.36 + (20, 184, 242)[j]*.64) for j in range(3))
        draw.ellipse((cx-radius, cy-radius, cx+radius, cy+radius), outline=(10, 69, 114), width=3)
    panel.paste(scene, (10, 50))
    text = ImageDraw.Draw(panel)
    text.text((12, 10), title, font=title_font, fill=(255, 255, 255))
    text.text((12, 453), subtitle, font=note_font, fill=(213, 220, 225))
    cards.append(panel)
out = Image.new('RGB', (620*3, 475), (27, 34, 44))
for i, card in enumerate(cards): out.paste(card, (i*620, 0))
meta = PngImagePlugin.PngInfo()
meta.add_text('Description', 'Headless OpenFront World renderer crop; visibility mockups, not a Roblox Studio screenshot.')
meta.add_text('Attribution', 'OpenFront map resources, CC BY-SA 4.0. Credit: OpenFront.')
target = Path('tests/fixtures/OpenFrontOwnTerritoryOptions.png')
out.save(target, pnginfo=meta)
print(target)
