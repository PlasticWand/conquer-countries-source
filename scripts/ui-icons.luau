--!strict
-- lune run scripts/ui-icons
-- Original, tintable Signal Corps masks plus two cream nine-slice frames.
-- The only shared machinery with Stunt Yard is the ordinary SDF/PNG approach.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local Art = luau.load(fs.readFile("src/client/Map/IconArt.luau"))()
local Crc32 = luau.load(fs.readFile("src/shared/Crc32.luau"))()

local function directory(path: string)
	local current = ""
	for part in string.gmatch(path, "[^/]+") do
		current ..= (if current == "" then "" else "/") .. part
		if not fs.isDir(current) then fs.writeDir(current) end
	end
end

local function png(width: number, height: number, rgba: buffer): string
	local function chunk(kind: string, data: string): string
		return string.pack(">I4", #data) .. kind .. data .. string.pack(">I4", Crc32.ofString(kind .. data))
	end
	local rows = buffer.create(height * (width * 4 + 1))
	for row = 0, height - 1 do buffer.copy(rows, row * (width * 4 + 1) + 1, rgba, row * width * 4, width * 4) end
	return "\137PNG\r\n\26\n" .. chunk("IHDR", string.pack(">I4I4BBBBB", width, height, 8, 6, 0, 0, 0))
		.. chunk("IDAT", serde.compress("zlib", buffer.tostring(rows))) .. chunk("IEND", "")
end

local function canvas(width: number, height: number, color: {number}): buffer
	local pixels = buffer.create(width * height * 4)
	for tile = 0, width * height - 1 do
		for channel = 0, 2 do buffer.writeu8(pixels, tile * 4 + channel, color[channel + 1]) end
		buffer.writeu8(pixels, tile * 4 + 3, 255)
	end
	return pixels
end

local function blit(target: buffer, width: number, source: buffer, side: number, ox: number, oy: number, tint: {number})
	for y = 0, side - 1 do
		for x = 0, side - 1 do
			local src, dst = (y * side + x) * 4, ((oy + y) * width + ox + x) * 4
			local alpha = buffer.readu8(source, src + 3) / 255
			for channel = 0, 2 do
				local before = buffer.readu8(target, dst + channel)
				buffer.writeu8(target, dst + channel, math.round(before + (tint[channel + 1] - before) * alpha))
			end
		end
	end
end

local function panel(tape: boolean): buffer
	local pixels = buffer.create(64 * 64 * 4)
	for y = 0, 63 do
		for x = 0, 63 do
			local inset = if tape then math.max(2, 9 - y, y - 54) else (if y < 2 or y > 61 then 2 else 1)
			if x < inset or x > 63 - inset or y < 1 or y > 62 then continue end
			local offset = (y * 64 + x) * 4
			local edge = x == inset or x == 63 - inset or y == 1 or y == 62
			local grain = ((x * 7919 + y * 6271 + x * y * 23) % 97 / 96 - 0.5) * 2
			local rgb = if edge then {156, 148, 116} else {236 + grain, 228 + grain, 205 + grain}
			for channel = 0, 2 do buffer.writeu8(pixels, offset + channel, math.round(rgb[channel + 1])) end
			buffer.writeu8(pixels, offset + 3, 255)
		end
	end
	return pixels
end

local function slicePreview(target: buffer, targetWidth: number, pixels: buffer, left: number, top: number,
	right: number, bottom: number, x0: number, y0: number, width: number, height: number)
	local function axis(value: number, length: number, first: number, last: number): number
		if value < first then return value end
		if value >= length - (64 - last) then return 64 - (length - value) end
		return first + math.floor((value - first) / (length - first - (64 - last)) * (last - first))
	end
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local src = (axis(y, height, top, bottom) * 64 + axis(x, width, left, right)) * 4
			local dst = ((y0 + y) * targetWidth + x0 + x) * 4
			local alpha = buffer.readu8(pixels, src + 3) / 255
			for channel = 0, 2 do
				local before = buffer.readu8(target, dst + channel)
				buffer.writeu8(target, dst + channel, math.round(before + (buffer.readu8(pixels, src + channel) - before) * alpha))
			end
		end
	end
end

directory("assets/ui/icons")
directory("assets/ui/frames")
local ink = {31, 35, 26}
local contact = canvas(800, 640, {236, 228, 205})
local entries = {}
for index, name in Art.names do
	local pixels = Art.render(name, 96, {255, 255, 255})
	fs.writeFile(`assets/ui/icons/{name}.png`, png(96, 96, pixels))
	table.insert(entries, {name = name, file = `icons/{name}.png`, width = 96, height = 96, tint = "#1F231A"})
	local ox, oy = ((index - 1) % 5) * 160, math.floor((index - 1) / 5) * 160
	blit(contact, 800, pixels, 96, ox + 32, oy + 6, ink)
	blit(contact, 800, Art.render(name, 24), 24, ox + 44, oy + 118, ink)
	blit(contact, 800, Art.render(name, 32), 32, ox + 86, oy + 114, ink)
end
fs.writeFile("assets/ui/icons-preview.png", png(800, 640, contact))
local tape, cream = panel(true), panel(false)
fs.writeFile("assets/ui/frames/tape-label.png", png(64, 64, tape))
fs.writeFile("assets/ui/frames/cream-panel.png", png(64, 64, cream))
local frames = canvas(640, 320, {44, 49, 37})
slicePreview(frames, 640, tape, 12, 12, 52, 52, 24, 24, 280, 56)
slicePreview(frames, 640, tape, 12, 12, 52, 52, 336, 24, 280, 80)
slicePreview(frames, 640, cream, 8, 8, 56, 56, 24, 128, 280, 160)
slicePreview(frames, 640, cream, 8, 8, 56, 56, 336, 128, 280, 160)
fs.writeFile("assets/ui/frames-preview.png", png(640, 320, frames))
fs.writeFile("assets/ui/manifest.json", serde.encode("json", {schema = 1, generator = "scripts/ui-icons.luau", icons = entries,
	frames = {{file = "frames/tape-label.png", sliceCenter = {12, 12, 52, 52}, contentInset = {left = 14, right = 14, top = 4, bottom = 4}},
		{file = "frames/cream-panel.png", sliceCenter = {8, 8, 56, 56}, contentInset = 12}}}, true))
fs.writeFile("assets/ui/README.md", [[# Signal Corps UI art

Original code-drawn art, 2026-10-20. Run `lune run scripts/ui-icons` from the project root to regenerate every PNG, preview and manifest. Geometry is in `src/client/Map/IconArt.luau`; the map uses the same four city/port/fort/boat masks in its own tiny runtime atlas. No generated images, reference assets, fonts or external raster libraries enter this pipeline.

## Icons

`icons/*.png`: nineteen 96x96 straight-alpha, anti-aliased white masks. Set `ImageColor3 = Theme.color.ink` on cream, `Theme.color.cream` on olive. White RGB allows both tints without a second upload. Each icon has at least 8 source pixels of transparent breathing room. `icons-preview.png` displays each mask at 96, 24 and 32 pixels in dark ink on cream. Grid order, left to right then top to bottom:

troops, capacity, growth, gold, land; rank, clock, flag, alert, city; port, fort, boat, attack, alliance; ping, crown, close, chevron.

Silhouette meanings: ready troops = three people; capacity = a person within a perimeter; growth = rising bars; gold = ingot; land = globe; rank = medal; clock = dial; flag = banner; alert = warning triangle; city = three towers; port = anchor; fort = crenellated gate; boat = transport hull; attack = crossed swords; alliance = clasped hands; ping = smiling speech bubble; crown = leader; close = cross; chevron = next. These are deliberately bold at 24 pixels, with no baked words or ornamental outlines.

## Frames

Both are 64x64 RGBA with a transparent exterior, cream fill (#ECE4CD), one-pixel olive/ink rule and subtle deterministic paper grain. Leave `ImageColor3` white. Use `ScaleType = Enum.ScaleType.Slice`, `SliceScale = 1` at the design scale and the following `SliceCenter`:

| File | Rect.new(x0, y0, x1, y1) | Content inset |
| --- | --- | --- |
| frames/tape-label.png | Rect.new(12, 12, 52, 52) | 14 px horizontal, 4 px vertical |
| frames/cream-panel.png | Rect.new(8, 8, 56, 56) | 12 px |

Keep small tape labels at least 48x28 and panels at least 32x32 before overall UIScale; panel content may need more height than that geometric minimum. Corners and edge rules stay in the fixed slices; the center can stretch. `frames-preview.png` renders the actual nine-slice mapping at two tape heights and two panel placements. Do not put text into an ImageLabel; layer live TextLabels over these frames.

Uploads are not performed by this script. Claude uploads the 19 masks and 2 frames, then supplies asset IDs to the HUD. Previews and manifest are review artifacts, not assets to upload.
]])
print("Wrote 19 icons, 2 frames, 2 previews and the manifest to assets/ui")
