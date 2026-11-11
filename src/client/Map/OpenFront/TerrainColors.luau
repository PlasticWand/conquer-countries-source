--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/utils/ColorUtils.ts; src/client/render/gl/render-settings.json), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Js = require(script.Parent.JsMath)
export type RGB = {number}
export type Colors = {backgroundColor: RGB?, oceanColor: RGB?, sandColor: RGB?, plainsColor: RGB?, highlandColor: RGB?, mountainColor: RGB?}
local Terrain = {}
Terrain.defaults = {backgroundColor = {60, 60, 60}, oceanColor = {71, 133, 181}, sandColor = {204, 203, 158},
	plainsColor = {190, 220, 138}, highlandColor = {220, 203, 158}, mountainColor = {230, 230, 230}}

-- Original: ColorUtils.hexToRgb.
function Terrain.hexToRgb(hex: string): RGB?
	local digits = hex:match("^%s*#?(%x%x%x%x%x%x)%s*$")
	if not digits then return nil end
	local n = tonumber(digits, 16) :: number
	return {bit32.band(bit32.rshift(n, 16), 255), bit32.band(bit32.rshift(n, 8), 255), bit32.band(n, 255)}
end

-- Original: ColorUtils.encodeTerrainTile. nil overrides use ColorUtils'
-- historical highland fallback (200,183,138); the live RenderSettings override
-- is (220,203,158), so callers wanting the live look pass Terrain.defaults.
function Terrain.encodeTerrainTile(tb: number, out: buffer, offset: number, colors: Colors?)
	local c: Colors = colors or {}
	local land, shore, magnitude = bit32.btest(tb, 128), bit32.btest(tb, 64), bit32.band(tb, 31)
	local r, g, b: number
	if land and magnitude == 31 then
		local base = c.backgroundColor or Terrain.defaults.backgroundColor
		r, g, b = base[1], base[2], base[3]
	elseif land and shore then
		local base = c.sandColor or Terrain.defaults.sandColor
		r, g, b = base[1], base[2], base[3]
	elseif land then
		if magnitude < 10 then
			local base = c.plainsColor or Terrain.defaults.plainsColor
			r, g, b = base[1], base[2] - 2 * magnitude, base[3]
		elseif magnitude < 20 then
			local base, m = c.highlandColor or {200, 183, 138}, magnitude - 10
			r, g, b = math.min(255, base[1] + 2 * m), math.min(255, base[2] + 2 * m), math.min(255, base[3] + 2 * m)
		else
			local base, m = c.mountainColor or Terrain.defaults.mountainColor, math.floor(magnitude / 2)
			r, g, b = math.min(255, base[1] + m), math.min(255, base[2] + m), math.min(255, base[3] + m)
		end
	elseif shore then
		local base = c.oceanColor or Terrain.defaults.oceanColor
		r, g, b = Js.round(.7 * base[1] + 76.5), Js.round(.7 * base[2] + 76.5), Js.round(.7 * base[3] + 76.5)
	else
		local base, m = c.oceanColor or Terrain.defaults.oceanColor, math.min(magnitude, 10)
		r, g, b = math.max(0, base[1] - m), math.max(0, base[2] - m), math.max(0, base[3] - m)
	end
	-- Uint8Array assignment truncates and wraps; buffer.writeu8 has the same
-- conversion for finite numbers. Overrides are validated RGB bytes upstream.
	buffer.writeu8(out, offset, r); buffer.writeu8(out, offset + 1, g); buffer.writeu8(out, offset + 2, b)
	buffer.writeu8(out, offset + 3, 255)
end

-- Original: ColorUtils.buildTerrainRGBA, factored into a 256-entry byte LUT.
function Terrain.palette(colors: Colors?): buffer
	local out = buffer.create(1024)
	for byte = 0, 255 do Terrain.encodeTerrainTile(byte, out, byte * 4, colors) end
	return out
end

-- Original: ColorUtils.buildTerrainRGBA.
function Terrain.buildTerrainRGBA(terrain: buffer, w: number, h: number, colors: Colors?): buffer
	assert(buffer.len(terrain) == w * h, "terrain dimensions differ")
	local lut, out = Terrain.palette(colors), buffer.create(w * h * 4)
	for tile = 0, w * h - 1 do buffer.writeu32(out, tile * 4, buffer.readu32(lut, buffer.readu8(terrain, tile) * 4)) end
	return out
end

return Terrain
