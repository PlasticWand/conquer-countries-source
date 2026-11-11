--!strict
-- Number and time formatting for every screen and map label, so the HUD and
-- the renderer always agree (12.4K, 1.25M, 2:05).

local Format = {}

function Format.troops(n: number): string
	n = math.floor(n)
	local a = math.abs(n)
	local sign = if n < 0 then "-" else ""
	if a < 1000 then
		return sign .. tostring(a)
	elseif a < 10000 then
		return sign .. string.format("%.1fK", math.floor(a / 100) / 10)
	elseif a < 1000000 then
		return sign .. string.format("%dK", math.floor(a / 1000))
	elseif a < 10000000 then
		return sign .. string.format("%.2fM", math.floor(a / 10000) / 100)
	else
		return sign .. string.format("%.1fM", math.floor(a / 100000) / 10)
	end
end

function Format.percent(share: number, decimals: number?): string
	return string.format(`%.{decimals or 1}f%%`, share * 100)
end

function Format.clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

return Format
