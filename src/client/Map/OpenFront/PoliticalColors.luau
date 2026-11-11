--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/shaders/map-overlay/territory.frag.glsl; src/client/render/gl/shaders/border-compute/border-compute.frag.glsl; src/client/render/gl/shaders/day-night/border-stamp.frag.glsl), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Defaults = require(script.Parent.RenderDefaults)
export type RGB = {r: number, g: number, b: number}
export type RGBA = {r: number, g: number, b: number, a: number}
export type Neighbour = {owner: number, relation: number}
export type Border = {borderType: number, relation: number}
export type Tile = {owner: number, x: number, y: number, defended: boolean, hovered: boolean,
	altView: boolean?, affiliation: RGB?, fallout: boolean?, secondaryPattern: boolean?}
local Political = {}
local CLEAR: RGBA = {r = 0, g = 0, b = 0, a = 0}

-- Original: border-compute.frag main. getOwner must return zero off-map;
-- a caller can supply its cached Chebyshev halo for highlight expansion.
function Political.border(owner: number, neighbours: {Neighbour}, hovered: boolean, x: number, y: number,
	getOwner: ((number, number) -> number)?, thickness: number?): Border
	local kind, relation = 0, 0
	if owner ~= 0 then
		for _, n in neighbours do
			if n.owner ~= owner then
				kind = 0.5
				if n.owner ~= 0 then relation = math.max(relation, n.relation) end
			end
		end
		if hovered then
			if kind > 0 then kind = 1
			elseif getOwner then
				for d = 1, math.min(10, thickness or Defaults.mapOverlay.highlightThicken) do
					for i = -d, d do
						if getOwner(x + i, y - d) ~= owner or getOwner(x + i, y + d) ~= owner then kind = 1; break end
					end
					if kind == 0 then
						for i = -d + 1, d - 1 do
							if getOwner(x - d, y + i) ~= owner or getOwner(x + d, y + i) ~= owner then kind = 1; break end
						end
					end
					if kind > 0 then break end
				end
			end
		end
	end
	return {borderType = kind, relation = relation * 0.5}
end

-- Original: territory.frag main (palette/pattern selection before colour
-- maths). Inputs and output RGB/alpha are normalized floats, not bytes.
function Political.fill(tile: Tile, color: RGB, secondary: RGB, border: Border,
	settings: typeof(Defaults.mapOverlay)?, altFillAlpha: number?): RGBA
	local s = settings or Defaults.mapOverlay
	if tile.owner == 0 and not tile.fallout then return table.clone(CLEAR) end
	if tile.fallout then
		local value = math.sin(tile.x * 12.9898 + tile.y * 78.233) * 43758.5453
		local noise = s.staleNukeBase + (value - math.floor(value)) * s.staleNukeVariation
		return {r = s.staleNukeR + noise, g = s.staleNukeG + noise, b = s.staleNukeB + noise, a = s.staleNukeAlpha}
	end
	if tile.altView then
		local c = assert(tile.affiliation, "alternate view requires affiliation colour")
		return {r = c.r, g = c.g, b = c.b, a = altFillAlpha or Defaults.altView.fillAlpha}
	end
	local c = if tile.secondaryPattern then secondary else color
	local r, g, b = c.r, c.g, c.b
	if tile.owner ~= 0 and tile.hovered and s.highlightFillBrighten > 0 then
		local contrast = 1 + s.highlightFillBrighten
		r, g, b = math.clamp((r - 0.5) * contrast + 0.5, 0, 1), math.clamp((g - 0.5) * contrast + 0.5, 0, 1), math.clamp((b - 0.5) * contrast + 0.5, 0, 1)
	end
	if tile.defended and border.borderType <= 0.25 then
		r *= s.territoryDefenseDarken; g *= s.territoryDefenseDarken; b *= s.territoryDefenseDarken
	end
	if s.territorySaturation ~= 1 then
		local luma = r * 0.299 + g * 0.587 + b * 0.114
		r, g, b = luma + (r - luma) * s.territorySaturation,
			luma + (g - luma) * s.territorySaturation, luma + (b - luma) * s.territorySaturation
	end
	return {r = r, g = g, b = b, a = s.territoryAlpha}
end

-- Original: border-stamp.frag main. Relation tint precedes the checker;
-- alternate view skips hover/tint/defence and uses pure affiliation colour.
function Political.stamp(tile: Tile, color: RGB, border: Border, settings: typeof(Defaults.mapOverlay)?): RGBA
	if border.borderType <= 0.25 or tile.owner == 0 then return table.clone(CLEAR) end
	local s = settings or Defaults.mapOverlay
	local c = if tile.altView then assert(tile.affiliation, "alternate view requires affiliation colour") else color
	local r, g, b = c.r, c.g, c.b
	if not tile.altView then
		if border.borderType > 0.75 then
			r += (1 - r) * s.highlightBrighten; g += (1 - g) * s.highlightBrighten; b += (1 - b) * s.highlightBrighten
		end
		local tint, tr, tg, tb = 0, 0, 0, 0
		if border.relation > 0.75 then tint, tr, tg, tb = s.embargoTintRatio, s.embargoTintR, s.embargoTintG, s.embargoTintB
		elseif border.relation > 0.25 then tint, tr, tg, tb = s.friendlyTintRatio, s.friendlyTintR, s.friendlyTintG, s.friendlyTintB end
		r += (tr - r) * tint; g += (tg - g) * tint; b += (tb - b) * tint
		if tile.defended and (tile.x + tile.y) % 2 == 1 then
			r *= s.defenseCheckerDarken; g *= s.defenseCheckerDarken; b *= s.defenseCheckerDarken
		end
	end
	return {r = r, g = g, b = b, a = 1}
end

-- Original: Renderer fill then opaque border stamp layer order. This helper
-- returns the final political pixel; terrain blending remains the caller's.
function Political.rgba(tile: Tile, fillColor: RGB, borderColor: RGB, border: Border,
	settings: typeof(Defaults.mapOverlay)?, altFillAlpha: number?): RGBA
	local fill = Political.fill(tile, fillColor, borderColor, border, settings, altFillAlpha)
	local stamp = Political.stamp(tile, borderColor, border, settings)
	return if stamp.a > 0 then stamp else fill
end

return Political
