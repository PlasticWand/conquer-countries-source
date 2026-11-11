--!strict
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/Format.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- How OpenFront writes numbers. Troops are shown divided by 10.

local Format = {}

-- JS Number.prototype.toFixed for the small precisions used here.
local function toFixed(value: number, digits: number): string
	return string.format(`%.{digits}f`, value)
end

-- Format.ts renderNumber
function Format.renderNumber(num: number, fixedPoints: number?): string
	num = math.max(num, 0)
	if num >= 10_000_000_000 then
		return toFixed(math.floor(num / 100000000) / 10, fixedPoints or 1) .. "B"
	elseif num >= 1_000_000_000 then
		return toFixed(math.floor(num / 10000000) / 100, fixedPoints or 2) .. "B"
	elseif num >= 10_000_000 then
		return toFixed(math.floor(num / 100000) / 10, fixedPoints or 1) .. "M"
	elseif num >= 1_000_000 then
		return toFixed(math.floor(num / 10000) / 100, fixedPoints or 2) .. "M"
	elseif num >= 100000 then
		return tostring(math.floor(num / 1000)) .. "K"
	elseif num >= 10000 then
		return toFixed(math.floor(num / 100) / 10, fixedPoints or 1) .. "K"
	elseif num >= 1000 then
		return toFixed(math.floor(num / 10) / 100, fixedPoints or 2) .. "K"
	end
	return tostring(math.floor(num))
end

-- Format.ts renderTroops
function Format.renderTroops(troops: number): string
	return Format.renderNumber(troops / 10)
end

return Format
