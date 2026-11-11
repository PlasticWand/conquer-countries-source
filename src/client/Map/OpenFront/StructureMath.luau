--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/shaders/structure/structure.vert.glsl; src/client/render/gl/RenderOverrides.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Defaults = require(script.Parent.RenderDefaults)
local Policy = require(script.Parent.RenderPolicy)
local Structure = {}
export type Size = {iconScale: number, halfSize: number, screenSize: number, uvExpand: number, dots: boolean}

-- Original: structure.vert main LOD, geometry and icon UV expansion. The
-- returned screenSize is in backing pixels; divide by DPR for CSS pixels.
function Structure.size(kind: string, zoom: number, settings: typeof(Defaults.structure)?): Size
	local s = settings or Defaults.structure
	local shape = (s.shapes :: {[string]: {scale: number, iconFill: number}})[kind]
	assert(shape, `unknown OpenFront structure {kind}`)
	local scale = if zoom <= s.dotsZoomThreshold then s.dotScale
		elseif zoom >= s.iconGrowZoom then zoom / s.iconGrowZoom else math.min(1, zoom / s.iconScaleFactorZoomedOut)
	local half = s.iconSize * scale * 0.5 / zoom * shape.scale
	return {iconScale = scale, halfSize = half, screenSize = half * 2 * zoom,
		uvExpand = shape.scale / shape.iconFill, dots = zoom <= s.dotsZoomThreshold}
end

-- Bruno's 2026-10-27 presentation override: approximately half size, with
-- continuous zoom growth instead of fixed dots / the source's 3..7 plateau.
-- size() above remains the exact source oracle and can be restored by policy.
function Structure.presentationSize(kind: string, zoom: number): number
	if not Policy.continuousStructureZoom then return Structure.size(kind,zoom).screenSize*Policy.structureScale end
	local s=Defaults.structure
	local shape=(s.shapes :: {[string]: {scale: number, iconFill: number}})[kind]
	local scale
	if zoom<=s.dotsZoomThreshold then scale=s.dotScale*(.75+.25*zoom/s.dotsZoomThreshold)
	elseif zoom<s.iconScaleFactorZoomedOut then
		scale=s.dotScale+(1-s.dotScale)*(zoom-s.dotsZoomThreshold)/(s.iconScaleFactorZoomedOut-s.dotsZoomThreshold)
	elseif zoom<s.iconGrowZoom then scale=1+.1*(zoom-s.iconScaleFactorZoomedOut)/(s.iconGrowZoom-s.iconScaleFactorZoomedOut)
	else scale=1.1*zoom/s.iconGrowZoom end
	return s.iconSize*scale*shape.scale*Policy.structureScale
end

-- Original: applyGraphicsOverrides classicIcons branch (default is true).
function Structure.style(classicIcons: boolean?): {fillDarken: number, borderDarken: number, iconDarken: number, iconAlpha: number}
	if classicIcons == nil or classicIcons then return {fillDarken = 1, borderDarken = 0.7, iconDarken = 0.3, iconAlpha = 0.9} end
	local s = Defaults.structure
	return {fillDarken = s.fillDarken, borderDarken = s.borderDarken, iconDarken = s.iconDarken, iconAlpha = s.iconAlpha}
end

return Structure
