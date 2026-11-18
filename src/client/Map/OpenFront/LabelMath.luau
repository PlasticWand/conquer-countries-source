--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/shaders/name/name.vert.glsl; src/client/render/gl/passes/name-pass/index.ts; packages/engine-lib/src/Format.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Defaults = require(script.Parent.RenderDefaults)
local Label = {}
export type Sizing = {nameWorldScale: number, worldScale: number, screenSize: number, visible: boolean,
	nameSize: number, nameScale: number, lineOffsetY: number}
export type Color = {r: number, g: number, b: number}

-- Original: resources/atlases/msdf-atlas.json info.size/common.base. The
-- shader's 36-unit baseline is for layout/culling, not a 36px font em.
Label.fontSize, Label.fontBase = 48, 36

-- Original: name.vert main sizing/culling/target boost. cameraScale is the
-- matrix X scale (2*backing-pixel zoom/canvas width), not viewport CSS zoom.
function Label.size(size: number, cameraScale: number, troopLine: boolean, hovered: boolean, targeted: boolean,
	settings: typeof(Defaults.name)?): Sizing
	local s = settings or Defaults.name
	local base = math.max(1, math.floor(size))
	local nameSize = math.max(4, math.floor(base * s.nameScaleFactor))
	local nameScale = math.min(base * 0.25, s.nameScaleCap)
	local nameWorldScale = nameSize * nameScale / 48
	local worldScale = nameWorldScale * (if troopLine then s.troopSizeMultiplier else 1)
	local screenSize = nameWorldScale * 36 * math.abs(cameraScale)
	if targeted and screenSize < s.cullThreshold then
		local boost = s.cullThreshold / screenSize
		nameWorldScale *= boost; worldScale *= boost; screenSize = s.cullThreshold
	end
	return {nameWorldScale = nameWorldScale, worldScale = worldScale, screenSize = screenSize,
		visible = screenSize >= s.cullThreshold or hovered, nameSize = nameSize, nameScale = nameScale,
		lineOffsetY = if troopLine then 36 * nameWorldScale * 1.1 else 0}
end

-- Original: name.vert interpolation; NamePass.updateNames rebase uses same t.
function Label.lerp(from: number, to: number, elapsedSeconds: number, speed: number?): number
	local t = math.clamp(1 - math.exp(-(speed or Defaults.name.lerpSpeed) * elapsedSeconds), 0, 1)
	return from + (to - from) * t
end

-- Original: NamePass.updateNames troopBucket. Slot indices are zero based.
function Label.troopBucket(nowSeconds: number, slotIndex: number): number
	return math.floor((nowSeconds + (slotIndex % 5) * 0.1) / 0.5)
end

-- Original: NamePass.updateNames nameShade branch (human 0, nation .3, bot .4).
function Label.nameShade(playerType: number): number
	return if playerType == 2 then Defaults.name.nameShadeNation
		elseif playerType == 1 then Defaults.name.nameShadeBot else 0
end

-- Original: name.frag defaultFill = vec3(vNameShade), for BOTH text lines.
-- NamePass writes 0 for humans, .3 for nations and .4 for bots. These are
-- dark fill values, not amounts to subtract from white.
function Label.colors(playerType: number, territory: Color, settings: typeof(Defaults.name)?): {fill: Color, outline: Color, outlineWidth: number}
	local s = settings or Defaults.name
	local shade = if playerType == 2 then s.nameShadeNation elseif playerType == 1 then s.nameShadeBot else 0
	return {fill = if s.fillUsePlayerColor then territory else {r = shade, g = shade, b = shade},
		outline = if s.outlineUsePlayerColor then territory else {r = s.outlineR, g = s.outlineG, b = s.outlineB},
		outlineWidth = s.outlineWidth}
end

-- Original: name.vert em scale and 1.1*baseline troop-line offset. A Roblox
-- UIScale preserves source projection beyond TextSize's 100px ceiling; it
-- must not magnify the screen-space outline along with the glyphs.
function Label.project(sizing: Sizing, zoom: number): {namePixels: number, troopPixels: number, lineOffset: number, guiScale: number}
	local namePixels = sizing.nameWorldScale * zoom * Label.fontSize
	return {namePixels = namePixels, troopPixels = namePixels * Defaults.name.troopSizeMultiplier,
		lineOffset = sizing.nameWorldScale * zoom * Label.fontBase * 1.1,
		guiScale = math.max(1, namePixels / 100)}
end

-- Bruno's Roblox presentation override: cap the name em to a viewport share,
-- scaling the complete annotation uniformly. Source visibility is unchanged.
function Label.limitHeight(sizing: Sizing, zoom: number, height: number, fraction: number?): Sizing
	if not fraction or fraction<=0 then return sizing end
	local em=sizing.nameWorldScale*math.abs(zoom)*Label.fontSize
	local factor=math.min(1,math.max(0,height)*fraction/math.max(em,1e-9))
	if factor==1 then return sizing end
	local out=table.clone(sizing)
	out.nameWorldScale*=factor; out.worldScale*=factor; out.lineOffsetY*=factor
	return out
end

-- Studio filming override. Source LOD stays authoritative; scale the complete
-- visible annotation to an export-sized em without modifying the source cache.
function Label.filmHeight(sizing: Sizing, zoom: number, height: number, pixels: number): Sizing
	local factor = pixels * height / 1920 / math.max(sizing.nameWorldScale * math.abs(zoom) * Label.fontSize, 1e-9)
	local out = table.clone(sizing)
	out.nameWorldScale *= factor; out.worldScale *= factor; out.lineOffsetY *= factor
	return out
end

-- Original: Format.renderNumber's Number.toFixed boundary. Decimal limbs
-- round the exact IEEE-754 value, ties upward (C printf uses ties-to-even).
local function toFixed(value: number, digits: number): string
	assert(digits >= 0 and digits <= 100 and digits % 1 == 0, "toFixed digits out of range")
	if value ~= value then return "NaN" elseif value == math.huge then return "Infinity" end
	if value >= 1e21 then return tostring(value) end
	local mantissa, exponent = math.frexp(value)
	local integer = string.format("%.0f", mantissa * 2 ^ 53)
	local limbs: {number} = {}
	for i = #integer, 1, -1 do table.insert(limbs, tonumber(integer:sub(i, i)) :: number) end
	local function multiply(factor: number)
		local carry = 0
		for i, limb in limbs do local n = limb * factor + carry; limbs[i] = n % 10; carry = math.floor(n / 10) end
		while carry > 0 do table.insert(limbs, carry % 10); carry = math.floor(carry / 10) end
	end
	for _ = 1, digits do multiply(5) end
	local shift = exponent - 53 + digits
	if shift >= 0 then for _ = 1, shift do multiply(2) end
	else
		local bit = 0
		for _ = 1, -shift do
			local carry = 0
			for i = #limbs, 1, -1 do local n = carry * 10 + limbs[i]; limbs[i] = math.floor(n / 2); carry = n % 2 end
			bit = carry
		end
		if bit == 1 then
			local i = 1
			while limbs[i] == 9 do limbs[i] = 0; i += 1 end
			limbs[i] = (limbs[i] or 0) + 1
		end
	end
	while #limbs > 1 and limbs[#limbs] == 0 do table.remove(limbs) end
	local chars: {string} = {}
	for i = #limbs, 1, -1 do table.insert(chars, tostring(limbs[i])) end
	local result = table.concat(chars)
	if digits == 0 then return result end
	result = string.rep("0", math.max(0, digits + 1 - #result)) .. result
	return result:sub(1, #result - digits) .. "." .. result:sub(#result - digits + 1)
end

-- Original: Format.renderNumber (number input; bigint conversion is upstream).
function Label.renderNumber(value: number, fixedPoints: number?): string
	local n = math.max(value, 0)
	if n >= 10000000000 then return toFixed(math.floor(n / 100000000) / 10, fixedPoints or 1) .. "B"
	elseif n >= 1000000000 then return toFixed(math.floor(n / 10000000) / 100, fixedPoints or 2) .. "B"
	elseif n >= 10000000 then return toFixed(math.floor(n / 100000) / 10, fixedPoints or 1) .. "M"
	elseif n >= 1000000 then return toFixed(math.floor(n / 10000) / 100, fixedPoints or 2) .. "M"
	elseif n >= 100000 then return tostring(math.floor(n / 1000)) .. "K"
	elseif n >= 10000 then return toFixed(math.floor(n / 100) / 10, fixedPoints or 1) .. "K"
	elseif n >= 1000 then return toFixed(math.floor(n / 10) / 100, fixedPoints or 2) .. "K"
	else return tostring(math.floor(n)) end
end

-- Original: Format.renderTroops. Troops are displayed divided by ten.
function Label.renderTroops(troops: number): string
	return Label.renderNumber(troops / 10)
end

-- The source formatter discards these low digits before its decimal work.
-- Keep its magnitude too: equal coefficients across K/M/B are not equal text.
function Label.troopDisplayKey(troops: number): (number,number)
	local n=math.max(troops/10,0)
	if n>=10000000000 then return math.floor(n/100000000),7
	elseif n>=1000000000 then return math.floor(n/10000000),6
	elseif n>=10000000 then return math.floor(n/100000),5
	elseif n>=1000000 then return math.floor(n/10000),4
	elseif n>=100000 then return math.floor(n/1000),3
	elseif n>=10000 then return math.floor(n/100),2
	elseif n>=1000 then return math.floor(n/10),1
	else return math.floor(n),0 end
end

return Label
