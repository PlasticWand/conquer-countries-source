"""Bundle only pinned OpenFront resources/ FX (CC BY-SA 4.0, credit OpenFront).

Lossless RGBA run-length encoding; no upload or proprietary asset access.
"""
import base64
import hashlib
import json
import struct
from pathlib import Path
from PIL import Image

source = Path('../reference/openfront-v0.35.2/resources/atlases')
pixels = Image.open(source / 'fx-atlas.png').convert('RGBA')
assert pixels.size == (540, 242)
raw = pixels.tobytes()
runs = bytearray()
i = 0
while i < len(raw):
    color = raw[i:i+4]
    count = 1
    while count < 65535 and raw[i+count*4:i+(count+1)*4] == color:
        count += 1
    runs += struct.pack('<H', count) + color
    i += count*4
target = Path('src/client/Map/OpenFront/FxAtlasData.luau')
target.write_text('''--!strict
-- Ported from OpenFront v0.35.2 (resources/atlases/fx-atlas.png), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- OpenFront v0.35.2 resources/atlases/fx-atlas.png, CC BY-SA 4.0. Credit: OpenFront.
-- Adapted by the Conquest team: lossless RGBA runs (u16 count, RGBA), base64.
return [=[
''' + base64.b64encode(runs).decode() + '\n]=]\n', encoding='utf-8')
Path('tests/fixtures/OpenFrontFxAtlas.json').write_text(json.dumps({
    'source': 'OpenFrontIO v0.35.2 resources/atlases/fx-atlas.png',
    'rgbaSha256': hashlib.sha256(raw).hexdigest(),
    'rgbaBytes': len(raw),
    'runs': len(runs)//6,
    'metadata': json.loads((source / 'fx-atlas-meta.json').read_text()),
}, indent=2) + '\n')
print(f'{target}: {len(runs)} encoded bytes; {len(raw)} RGBA bytes')
