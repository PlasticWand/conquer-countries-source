--!strict
-- Ported from OpenFront v0.35.2 (name-pass/TextLayout.ts; shaders/name/icon.vert.glsl),
-- © OpenFront and Contributors, AGPL-3.0. Modified for Roblox by Conquest.
local Glyphs = require(script.Parent.NameGlyphMetrics)
local Js = require(script.Parent.JsMath)
local Flag = {}

function Flag.resolve(art: any, value: string?): any?
	if not art or not value or value == "" then return nil end
	local key = if string.sub(value, 1, 2) == "f_" or string.sub(value, 1, 2) == "o_" then value else "f_" .. string.lower(value)
	local cell = art.cells[key]
	if not cell then return nil end
	local own = string.sub(key, 1, 2) == "o_"
	local size = if own then art.own else art.country
	local page = (if own then art.OWN_PAGES else art.COUNTRY_PAGES)[cell[1]]
	if not page then return nil end
	return {key = key, page = page, x = cell[2] * size.w + 2, y = cell[3] * size.h + 2, w = size.w - 4, h = size.h - 4}
end

-- Same Uint8 char slots/visual bounds as source layoutString. Used before
-- native TextBounds is available; afterwards use the displayed font's bounds.
function Flag.halfWidth(text: string): number
	-- The native label adapter can supply a byte-truncated UTF-8 suffix.
	-- Measure its complete prefix until TextBounds arrives, rather than
	-- allowing a presentation-only fallback to abort the renderer.
	local _, invalid = utf8.len(text)
	if invalid then text = string.sub(text, 1, invalid - 1) end
	local codes = Js.utf16(text)
	local count = math.min(#codes, 32)
	if count == 0 then return 0 end
	local cursor, previous, last = 0, 0, 0
	local first = Glyphs.glyphs[codes[1] % 256]
	for i = 1, count do
		local code = codes[i] % 256
		local glyph = Glyphs.glyphs[code]
		last = cursor
		cursor += (if glyph then glyph[1] else 0) + (if i > 1 then Glyphs.kern[previous * 384 + code] or 0 else 0)
		previous = code
	end
	local glyph = Glyphs.glyphs[previous]
	return (last + (if glyph then glyph[2] + glyph[3] else 0) - (if first then first[2] else 0)) / 2
end

function Flag.layout(halfWidth: number, worldScale: number, zoom: number): (number, number, number, number)
	local h = 36 * worldScale * zoom * 1.2
	local w = h * 128 / 85
	return -halfWidth - w, -h / 2, w, h
end

return Flag
