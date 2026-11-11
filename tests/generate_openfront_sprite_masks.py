"""Embed CC BY-SA 4.0 OpenFront v0.35.2 renderer atlas masks as Luau data.

Run from the Conquest root with the pinned read-only reference clone in place.
Only resources/atlases is read. No proprietary asset is opened or copied.
"""
from base64 import b64encode
from pathlib import Path
from PIL import Image

source = Path('../reference/openfront-v0.35.2/resources/atlases')
unit = Image.open(source / 'unit-atlas.png').convert('RGBA')
icon = Image.open(source / 'icon-atlas.png').convert('RGBA')
assert unit.size == (156, 13) and icon.size == (384, 64)

# Four original grayscale replacement bands, then the six white glyph masks.
masks = bytearray()
for band in range(4):
    for y in range(13):
        for x in range(156):
            r, _, _, a = unit.getpixel((x, y))
            bucket = 0 if r > 153 else 1 if r > 114 else 2 if r > 86 else 3
            masks.append(a if bucket == band else 0)
for y in range(64):
    for x in range(384):
        masks.append(icon.getpixel((x, y))[3])

encoded = b64encode(masks).decode('ascii')
target = Path('src/client/Map/OpenFront/SpriteAtlasData.luau')
target.write_text('''--!strict
-- Ported from OpenFront v0.35.2 (resources/atlases/unit-atlas.png; resources/atlases/icon-atlas.png), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Source assets: OpenFront resources/, CC BY-SA 4.0. Credit: OpenFront.
-- Four 156×13 grayscale bands then one 384×64 icon alpha plane; base64.
return [=[
''' + encoded + '\n]=]\n', encoding='utf-8')
print(target, len(masks), 'mask bytes')
