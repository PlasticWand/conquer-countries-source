"""Generates a real-geography tile map from Natural Earth (public domain).

    python scripts/genmap-earth.py <naturalearth-dir> [preset] [landcover.tif]

<naturalearth-dir> holds ne_50m_land.geojson, ne_50m_lakes.geojson and
ne_50m_geography_regions_polys.geojson from
https://github.com/nvkelso/natural-earth-vector (public domain; "Made with
Natural Earth"). Writes src/shared/Maps/<Module>/ in the same format as
scripts/genmap-test.luau (CONTRACT.md section 2) and a preview PNG under
capture/maps/.

[landcover.tif] is Natural Earth I land cover, NE1_LR_LC.tif from
https://naciscdn.org/naturalearth/10m/raster/NE1_LR_LC.zip (public domain).
With it the map also gets an art-only biome layer (B<cx>_<cy> chunks,
TileMap.BIOME): each tile averages the raster over its footprint and is
classed by colour as grass, forest, jungle, dry, desert, tundra or snow.
Gameplay never reads biomes.

Projection: equirectangular with longitudes scaled by cos(middle latitude),
which keeps a regional map close to true shape. rowAreaWeight records each
row's relative ground area so victory share can be area-true later.
Terrain: Natural Earth mountain ranges become mountains with a highland rim;
plateaus become highland; everything else is plains. Lakes are water.
"""

import base64
import json
import math
import os
import sys
import zlib

from PIL import Image, ImageDraw, ImageFilter

PRESETS = {
    "europe": {
        "module": "Europe",
        "map_id": "europe",
        "lon": (-25.0, 45.0),
        "lat": (34.0, 71.5),
        "width": 520,
        "min_island": 14,
        "wrap": False,
        "labels": [
            ("North Sea", 3.0, 56.0, "sea"),
            ("Mediterranean Sea", 17.0, 36.0, "sea"),
            ("Baltic Sea", 19.5, 58.0, "sea"),
            ("Atlantic Ocean", -17.0, 48.0, "sea"),
            ("Black Sea", 34.0, 43.3, "sea"),
            ("Alps", 10.0, 46.5, "feature"),
            ("Pyrenees", 0.5, 42.7, "feature"),
            ("Carpathians", 24.0, 47.5, "feature"),
        ],
    },
    "world": {
        "module": "World",
        "map_id": "world",
        "lon": (-170.0, 190.0),
        "lat": (-56.0, 78.0),
        "width": 880,
        "min_island": 10,
        "wrap": True,
        "labels": [
            ("Pacific Ocean", -150.0, 5.0, "sea"),
            ("Atlantic Ocean", -35.0, 10.0, "sea"),
            ("Indian Ocean", 78.0, -18.0, "sea"),
        ],
    },
}

CHUNK = 128
SOURCE_BUDGET = 64 * 1024
GENERATOR_VERSION = 1


def load_features(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)["features"]


def rings_of(geometry):
    kind = geometry["type"]
    coords = geometry["coordinates"]
    if kind == "Polygon":
        return [coords]
    if kind == "MultiPolygon":
        return coords
    return []


def main():
    src = sys.argv[1]
    preset = PRESETS[sys.argv[2] if len(sys.argv) > 2 else "europe"]
    lon0, lon1 = preset["lon"]
    lat0, lat1 = preset["lat"]
    mid = math.radians((lat0 + lat1) / 2)
    xscale = math.cos(mid)
    width = preset["width"]
    span_x = (lon1 - lon0) * xscale
    span_y = lat1 - lat0
    height = int(round(width * span_y / span_x))

    def project(lon, lat):
        if preset["wrap"] and lon < lon0 - 30:
            lon += 360  # the world preset wraps the antimeridian
        x = (lon - lon0) * xscale / span_x * width
        y = (lat1 - lat) / span_y * height
        return (x, y)

    def draw_polys(draw, features, value, keep=lambda props: True):
        for feat in features:
            if not keep(feat.get("properties") or {}):
                continue
            for poly in rings_of(feat["geometry"]):
                outer = [project(lon, lat) for lon, lat in poly[0]]
                if len(outer) >= 3:
                    draw.polygon(outer, fill=value)
                for hole in poly[1:]:
                    pts = [project(lon, lat) for lon, lat in hole]
                    if len(pts) >= 3:
                        draw.polygon(pts, fill=0)

    land = Image.new("L", (width, height), 0)
    draw_polys(ImageDraw.Draw(land), load_features(os.path.join(src, "ne_50m_land.geojson")), 1)
    draw_polys(ImageDraw.Draw(land), load_features(os.path.join(src, "ne_50m_lakes.geojson")), 0)

    regions = load_features(os.path.join(src, "ne_50m_geography_regions_polys.geojson"))
    mountains = Image.new("L", (width, height), 0)
    def cla(p):
        return p.get("FEATURECLA") or p.get("featurecla")

    draw_polys(ImageDraw.Draw(mountains), regions, 255, lambda p: cla(p) == "Range/mtn")
    plateau = Image.new("L", (width, height), 0)
    draw_polys(ImageDraw.Draw(plateau), regions, 255, lambda p: cla(p) in ("Plateau", "Foothills"))
    # A highland rim around every range, a little wider than the range itself.
    rim = mountains.filter(ImageFilter.MaxFilter(7))

    lp, mp, rp, pp_ = land.load(), mountains.load(), rim.load(), plateau.load()
    terrain = bytearray(width * height)
    for y in range(height):
        for x in range(width):
            if lp[x, y]:
                # Mountain cores only where the range is deep inside its polygon.
                tag = 1
                if rp[x, y] or pp_[x, y]:
                    tag = 2
                if mp[x, y]:
                    tag = 3 if (x + y) % 1 == 0 else 2
                terrain[y * width + x] = tag

    # Thin the mountain cores: a range's outer band becomes highland.
    core = mountains.filter(ImageFilter.MinFilter(3)).load()
    for y in range(height):
        for x in range(width):
            i = y * width + x
            if terrain[i] == 3 and not core[x, y]:
                terrain[i] = 2

    # Drop specks smaller than min_island tiles (4-connected).
    seen = bytearray(width * height)
    for start in range(width * height):
        if terrain[start] and not seen[start]:
            stack = [start]
            seen[start] = 1
            comp = []
            while stack:
                i = stack.pop()
                comp.append(i)
                x = i % width
                for j in (i - 1 if x > 0 else -1, i + 1 if x < width - 1 else -1, i - width, i + width):
                    if 0 <= j < width * height and terrain[j] and not seen[j]:
                        seen[j] = 1
                        stack.append(j)
            if len(comp) < preset["min_island"]:
                for i in comp:
                    terrain[i] = 0

    land_count = sum(1 for t in terrain if t)

    # Biomes from land cover (art only): 0 grass, 1 forest, 2 jungle, 3 dry,
    # 4 desert, 5 tundra, 6 snow. The projection is linear in lon and lat, so a
    # crop of the raster resized with a box filter averages each tile exactly.
    biome = None
    if len(sys.argv) > 3:
        Image.MAX_IMAGE_PIXELS = None
        cover = Image.open(sys.argv[3]).convert("RGB")
        cw, ch = cover.size
        lon_span = span_x / xscale

        def crop_lon(a, b):
            return cover.crop((int((a + 180) / 360 * cw), int((90 - lat1) / 180 * ch),
                               int((b + 180) / 360 * cw), int((90 - lat0) / 180 * ch)))

        if lon0 + lon_span > 180:  # the world preset wraps the antimeridian
            east = crop_lon(lon0, 180)
            west = crop_lon(-180, lon0 + lon_span - 360)
            region = Image.new("RGB", (east.width + west.width, east.height))
            region.paste(east, (0, 0))
            region.paste(west, (east.width, 0))
        else:
            region = crop_lon(lon0, lon0 + lon_span)
        avg = region.resize((width, height), Image.BOX).load()

        biome = bytearray(width * height)
        for y in range(height):
            lat = lat1 - (y + 0.5) / height * span_y
            for x in range(width):
                if not terrain[y * width + x]:
                    continue
                r, g, b = avg[x, y]
                bright = (r + g + b) / 3
                if b - r >= 2 and bright >= 220:
                    tag = 6  # ice and snow (blue-white)
                elif abs(g - r) <= 5 and g - b <= 12 and b - r >= -14 and bright >= 205:
                    tag = 5  # tundra (flat grey)
                elif g - r >= 16:
                    tag = 2 if abs(lat) < 23.5 else 1  # forest; tropical forest is jungle
                elif (g - b <= 26 and b - r <= -20 and bright >= 225) or g - r <= -14:
                    tag = 4  # desert (pale tan or pink)
                elif g - r <= -5:
                    tag = 3  # dry steppe and savanna (warm tan)
                else:
                    tag = 0  # grass and farmland
                biome[y * width + x] = tag

        # A 3x3 majority filter over land removes single-tile speckle.
        smoothed = bytearray(biome)
        for y in range(1, height - 1):
            for x in range(1, width - 1):
                i = y * width + x
                if not terrain[i]:
                    continue
                votes = {}
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        j = i + dy * width + dx
                        if terrain[j]:
                            votes[biome[j]] = votes.get(biome[j], 0) + 1
                best = max(votes.items(), key=lambda kv: kv[1])
                if best[1] >= 5:
                    smoothed[i] = best[0]
        biome = smoothed

    def rle(data):
        out = bytearray()
        i = 0
        n = len(data)
        while i < n:
            tag = data[i]
            j = i + 1
            while j < n and data[j] == tag:
                j += 1
            length = j - i
            out.append(tag)
            while length >= 128:
                out.append((length & 0x7F) | 0x80)
                length >>= 7
            out.append(length)
            i = j
        return bytes(out)

    def luau_string(text):
        return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'

    out_dir = os.path.join("src", "shared", "Maps", preset["module"])
    if os.path.isdir(out_dir):
        for name in os.listdir(out_dir):
            os.remove(os.path.join(out_dir, name))
    else:
        os.makedirs(out_dir)

    cols, rows = math.ceil(width / CHUNK), math.ceil(height / CHUNK)

    def write_layer(layer, prefix):
        refs = []
        for cy in range(rows):
            for cx in range(cols):
                x0, y0 = cx * CHUNK, cy * CHUNK
                w, h = min(CHUNK, width - x0), min(CHUNK, height - y0)
                raw = bytearray()
                for row in range(h):
                    start = (y0 + row) * width + x0
                    raw += layer[start:start + w]
                raw = bytes(raw)
                packed = rle(raw)
                encoding, payload = ("rle", packed) if len(packed) < len(raw) else ("raw", raw)
                name = "%s%02d_%02d" % (prefix, cx, cy)
                source = (
                    "-- Generated by scripts/genmap-earth.py from Natural Earth. Do not edit.\n"
                    "return {\n"
                    f"\tcx = {cx},\n\tcy = {cy},\n\tw = {w},\n\th = {h},\n"
                    f"\tencoding = {luau_string(encoding)},\n"
                    f"\tdecodedLength = {w * h},\n"
                    f"\tchecksum = {zlib.crc32(raw) & 0xFFFFFFFF},\n"
                    f"\tdata = {luau_string(base64.b64encode(payload).decode('ascii'))},\n"
                    "}\n"
                )
                assert len(source) <= SOURCE_BUDGET, f"chunk {name} exceeds the 64 KiB budget"
                with open(os.path.join(out_dir, name + ".luau"), "w", encoding="utf-8", newline="\n") as f:
                    f.write(source)
                refs.append(f'\t\t{{ cx = {cx}, cy = {cy}, module = "{name}" }},')
        return refs

    refs = write_layer(terrain, "C")
    biome_refs = write_layer(biome, "B") if biome else []

    weights = []
    for y in range(height):
        lat = lat1 - (y + 0.5) / height * span_y
        weights.append("%.4f" % (math.cos(math.radians(lat)) / xscale))

    labels = []
    for text, lon, lat, kind in preset["labels"]:
        x, y = project(lon, lat)
        tile = int(min(height - 1, max(0, y))) * width + int(min(width - 1, max(0, x)))
        labels.append(f"\t\t{{ text = {luau_string(text)}, tile = {tile}, kind = {luau_string(kind)} }},")

    manifest = (
        "--!strict\n"
        "-- Generated by scripts/genmap-earth.py. Do not edit; regenerate instead.\n"
        "-- Geography: Natural Earth 1:50m land, lakes and mountain ranges (public domain).\n"
        "return {\n"
        "\tschemaVersion = 1,\n"
        f"\tmapId = {luau_string(preset['map_id'])},\n"
        "\tmapVersion = 1,\n"
        f"\twidth = {width},\n\theight = {height},\n\tchunkSize = {CHUNK},\n"
        "\tchunks = {\n" + "\n".join(refs) + "\n\t},\n"
        + ("\tbiomeChunks = {\n" + "\n".join(biome_refs) + "\n\t},\n" if biome_refs else "")
        + "\trowAreaWeight = { " + ", ".join(weights) + " },\n"
        "\tlabels = {\n" + "\n".join(labels) + "\n\t},\n"
        f"\tgenerator = {{ script = \"scripts/genmap-earth.py\", version = {GENERATOR_VERSION}, sources = {{ \"Natural Earth 1:50m (public domain)\""
        + (", \"Natural Earth I land cover (public domain)\"" if biome_refs else "")
        + " } },\n"
        "}\n"
    )
    with open(os.path.join(out_dir, "init.luau"), "w", encoding="utf-8", newline="\n") as f:
        f.write(manifest)

    colors = {0: (17, 27, 35), 1: (128, 140, 84), 2: (152, 136, 96), 3: (205, 200, 190)}
    preview = Image.new("RGB", (width, height))
    pp = preview.load()
    for y in range(height):
        for x in range(width):
            pp[x, y] = colors[terrain[y * width + x]]
    os.makedirs(os.path.join("capture", "maps"), exist_ok=True)
    preview.save(os.path.join("capture", "maps", preset["map_id"] + ".png"))
    if biome:
        biome_colors = [(168, 186, 110), (70, 120, 70), (40, 100, 60), (200, 180, 110), (228, 204, 150), (170, 170, 150), (240, 244, 248)]
        for y in range(height):
            for x in range(width):
                i = y * width + x
                if terrain[i]:
                    pp[x, y] = biome_colors[biome[i]]
        preview.save(os.path.join("capture", "maps", preset["map_id"] + "-biome.png"))
    print(f"{preset['map_id']}: {width}x{height}, land {land_count} tiles ({land_count * 100 // (width * height)}%), {len(refs)} chunks")


if __name__ == "__main__":
    main()
