--!strict
-- Ported from OpenFront v0.35.2 (src/client/theme/ColorAllocator.ts; src/client/theme/ThemeProvider.ts, colord dependency), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Colord compatibility arithmetic; see Colord-LICENSE.txt (MIT).
local Js = require(script.Parent.JsMath)
export type Color = {r: number, g: number, b: number, a: number}
export type Lab = {l: number, a: number, b: number, alpha: number}
export type Lch = {l: number, c: number, h: number, a: number}
export type Hsl = {h: number, s: number, l: number, a: number}
local Color = {}

-- Original: colord parseHex (the cosmetics schema and theme use hex strings).
function Color.fromHex(value: string): Color
	local hex = value:match("^%s*#(%x+)%s*$")
	if not hex or (#hex ~= 3 and #hex ~= 4 and #hex ~= 6 and #hex ~= 8) then return {r = 0, g = 0, b = 0, a = 1} end
	if #hex <= 4 then hex = hex:gsub(".", function(c) return c .. c end) end
	return {r = tonumber(hex:sub(1, 2), 16) :: number, g = tonumber(hex:sub(3, 4), 16) :: number,
		b = tonumber(hex:sub(5, 6), 16) :: number, a = if #hex == 8 then Js.round((tonumber(hex:sub(7, 8), 16) :: number) / 255, 2) else 1}
end

-- Original: colord roundRgba / toRgb. Do not round internal conversion RGB.
function Color.toRgb(c: Color): Color
	return {r = Js.round(c.r), g = Js.round(c.g), b = Js.round(c.b), a = Js.round(c.a, 3)}
end

-- Original: colord rgbaToHex / toHex.
function Color.toHex(c: Color): string
	local rgb = Color.toRgb(c)
	local result = string.format("#%02x%02x%02x", rgb.r, rgb.g, rgb.b)
	return if rgb.a < 1 then result .. string.format("%02x", Js.round(rgb.a * 255)) else result
end

-- Original: colord rgbaToHsva → hsvaToHsla (unrounded manipulation path).
function Color.toHsl(c: Color, rounded: boolean?): Hsl
	local maximum = math.max(c.r, c.g, c.b)
	local delta = maximum - math.min(c.r, c.g, c.b)
	local hh = if delta == 0 then 0 elseif maximum == c.r then (c.g - c.b) / delta
		elseif maximum == c.g then 2 + (c.b - c.r) / delta else 4 + (c.r - c.g) / delta
	local h = 60 * (if hh < 0 then hh + 6 else hh)
	local s = if maximum == 0 then 0 else delta / maximum * 100
	local v = maximum / 255 * 100
	local light = (200 - s) * v / 100
	local saturation = if light > 0 and light < 200 then s * v / 100 / (if light <= 100 then light else 200 - light) * 100 else 0
	if rounded then return {h = Js.round(h) % 360, s = Js.round(saturation), l = Js.round(light / 2), a = Js.round(c.a, 3)} end
	return {h = h, s = saturation, l = light / 2, a = c.a}
end

-- Original: colord hslaToHsva → hsvaToRgba (clamped parsing).
function Color.fromHsl(c: Hsl): Color
	local h, s, l = c.h % 360, math.clamp(c.s, 0, 100), math.clamp(c.l, 0, 100)
	s *= (if l < 50 then l else 100 - l) / 100
	local v = l + s
	s = if s > 0 then 2 * s / v * 100 else 0
	s /= 100
	v /= 100
	h = h / 360 * 6
	local hh = math.floor(h)
	local b, cc, d = v * (1 - s), v * (1 - (h - hh) * s), v * (1 - (1 - h + hh) * s)
	local index = hh % 6 + 1
	return {r = ({v, cc, b, b, d, v})[index] * 255, g = ({d, v, v, cc, b, b})[index] * 255,
		b = ({b, b, d, v, v, cc})[index] * 255, a = math.clamp(c.a, 0, 1)}
end

-- Original: colord darken → lighten; it uses unrounded HSL.
function Color.darken(c: Color, amount: number): Color
	local hsl = Color.toHsl(c)
	hsl.l = math.clamp(hsl.l - amount * 100, 0, 100)
	return Color.fromHsl(hsl)
end

-- Original: colord linearizeRgbChannel.
local function linear(value: number): number
	local ratio = value / 255
	return if ratio < 0.04045 then ratio / 12.92 else ((ratio + 0.055) / 1.055) ^ 2.4
end

-- Original: colord unlinearizeRgbChannel, clamped by RGB parser.
local function gamma(value: number): number
	return math.clamp((if value > 0.0031308 then 1.055 * value ^ (1 / 2.4) - 0.055 else 12.92 * value) * 255, 0, 255)
end

-- Original: colord rgbaToXyza: sRGB -> D65 -> Bradford D50, then clampXyza.
-- Keep both matrices and their operation order; combining/rounding the
-- coefficients changes rounded LCH and consequently team palette assignment.
local function xyz(c: Color): (number, number, number)
	local r, g, b = linear(c.r), linear(c.g), linear(c.b)
	local x = 100 * (0.4124564 * r + 0.3575761 * g + 0.1804375 * b)
	local y = 100 * (0.2126729 * r + 0.7151522 * g + 0.0721750 * b)
	local z = 100 * (0.0193339 * r + 0.1191920 * g + 0.9503041 * b)
	return math.clamp(1.0478112 * x + 0.0228866 * y + -0.0501270 * z, 0, 96.422),
		math.clamp(0.0295424 * x + 0.9904844 * y + -0.0170491 * z, 0, 100),
		math.clamp(-0.0092345 * x + 0.0150436 * y + 0.7521316 * z, 0, 82.521)
end

-- Original: colord rgbaToLaba (D50), then toLab's two-place rounding.
function Color.toLab(c: Color, rounded: boolean?): Lab
	local x, y, z = xyz(c)
	x /= 96.422; y /= 100; z /= 82.521
	local e, k = 216 / 24389, 24389 / 27
	x = if x > e then x ^ (1 / 3) else (k * x + 16) / 116
	y = if y > e then y ^ (1 / 3) else (k * y + 16) / 116
	z = if z > e then z ^ (1 / 3) else (k * z + 16) / 116
	local lab = {l = 116 * y - 16, a = 500 * (x - y), b = 200 * (y - z), alpha = c.a}
	if rounded then lab.l, lab.a, lab.b, lab.alpha = Js.round(lab.l, 2), Js.round(lab.a, 2), Js.round(lab.b, 2), Js.round(lab.alpha, 3) end
	return lab
end

-- Original: colord labaToRgba / xyzaToRgba.
function Color.fromLab(c: Lab): Color
	local e, k = 216 / 24389, 24389 / 27
	local l = math.clamp(c.l, 0, 400)
	local y = (l + 16) / 116
	local x, z = c.a / 500 + y, y - c.b / 200
	x = (if x ^ 3 > e then x ^ 3 else (116 * x - 16) / k) * 96.422
	y = (if l > k * e then ((l + 16) / 116) ^ 3 else l / k) * 100
	z = (if z ^ 3 > e then z ^ 3 else (116 * z - 16) / k) * 82.521
	local dx = 0.9555766 * x + -0.0230393 * y + 0.0631636 * z
	local dy = -0.0282895 * x + 1.0099416 * y + 0.0210077 * z
	local dz = 0.0122982 * x + -0.0204830 * y + 1.3299098 * z
	return {r = gamma(0.032404542 * dx - 0.015371385 * dy - 0.004985314 * dz),
		g = gamma(-0.009692660 * dx + 0.018760108 * dy + 0.000415560 * dz),
		b = gamma(0.000556434 * dx - 0.002040259 * dy + 0.010572252 * dz), a = math.clamp(c.alpha, 0, 1)}
end

-- Original: colord rgbaToLcha / roundLcha; axis rounding precedes hue.
function Color.toLch(c: Color): Lch
	local lab = Color.toLab(c)
	local a, b = Js.round(lab.a, 3), Js.round(lab.b, 3)
	local h = math.atan2(b, a) / math.pi * 180
	return {l = Js.round(lab.l, 2), c = Js.round(math.sqrt(a * a + b * b), 2),
		h = Js.round(if h < 0 then h + 360 else h, 2) % 360, a = Js.round(c.a, 3)}
end

-- Original: colord lchaToRgba / parseLcha.
function Color.fromLch(c: Lch): Color
	local angle = (c.h % 360) * math.pi / 180
	return Color.fromLab({l = math.clamp(c.l, 0, 100), a = c.c * math.cos(angle), b = c.c * math.sin(angle), alpha = c.a})
end

-- Original: colord getDeltaE00 and labPlugin.delta. Rounded LAB inputs,
-- normalized/rounded to .001 before allocator comparisons (ties matter).
function Color.delta(first: Color, second: Color): number
	local a, b = Color.toLab(first, true), Color.toLab(second, true)
	local c1, c2 = math.sqrt(a.a ^ 2 + a.b ^ 2), math.sqrt(b.a ^ 2 + b.b ^ 2)
	local mc, ml = (c1 + c2) / 2, (a.l + b.l) / 2
	local c7 = mc ^ 7
	local g = 0.5 * (1 - math.sqrt(c7 / (c7 + 25 ^ 7)))
	local a1, a2 = a.a * (1 + g), b.a * (1 + g)
	local cc1, cc2 = math.sqrt(a1 ^ 2 + a.b ^ 2), math.sqrt(a2 ^ 2 + b.b ^ 2)
	local meanC = (cc1 + cc2) / 2
	local h1 = if a1 == 0 and a.b == 0 then 0 else math.atan2(a.b, a1) * 180 / math.pi
	local h2 = if a2 == 0 and b.b == 0 then 0 else math.atan2(b.b, a2) * 180 / math.pi
	if h1 < 0 then h1 += 360 end; if h2 < 0 then h2 += 360 end
	local dh, distance = h2 - h1, math.abs(h2 - h1)
	if distance > 180 and h2 <= h1 then dh += 360 elseif distance > 180 and h2 > h1 then dh -= 360 end
	local H = if distance <= 180 then (h1 + h2) / 2 else (if h1 + h2 < 360 then h1 + h2 + 360 else h1 + h2 - 360) / 2
	local rad = math.pi / 180
	local T = 1 - .17 * math.cos(rad * (H - 30)) + .24 * math.cos(rad * 2 * H)
		+ .32 * math.cos(rad * (3 * H + 6)) - .2 * math.cos(rad * (4 * H - 63))
	local dL, dC = b.l - a.l, cc2 - cc1
	local dH = 2 * math.sin(rad * dh / 2) * math.sqrt(cc1 * cc2)
	local sL = 1 + .015 * (ml - 50) ^ 2 / math.sqrt(20 + (ml - 50) ^ 2)
	local sC, sH = 1 + .045 * meanC, 1 + .015 * meanC * T
	local theta = 30 * math.exp(-((H - 275) / 25) ^ 2)
	local mean7 = meanC ^ 7
	local rt = -2 * math.sqrt(mean7 / (mean7 + 25 ^ 7)) * math.sin(rad * 2 * theta)
	local difference = math.sqrt((dL / sL) ^ 2 + (dC / sC) ^ 2 + (dH / sH) ^ 2 + rt * dC * dH / (sC * sH))
	return math.clamp(Js.round(difference / 100, 3), 0, 1)
end

return Color
