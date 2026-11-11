--!strict
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/execution/utils/TribeNames.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Names for tribes: a map's custom tribes, else prefix + suffix from its
-- themes in tribeNameThemes (CC BY-SA 4.0), else the default theme.

local MapInfo = require(script.Parent.Data.MapInfo)
local TribeNameThemes = require(script.Parent.Data.TribeNameThemes)

local TribeNames = {}

export type CustomTribe = { name: string, coordinates: { number }? }
export type TribeNameData = { prefixes: { string }, suffixes: { string }, customTribes: { CustomTribe }? }

local themes = TribeNameThemes :: any

-- TribeNames.ts getMapInfo
function TribeNames.getMapInfo(mapType: string?): any?
	if mapType == nil then
		return nil
	end
	for _, m in MapInfo :: any do
		if m.type == mapType then
			return m
		end
	end
	return nil
end

-- TribeNames.ts resolveTribeNameData
function TribeNames.resolveTribeNameData(mapType: string?): TribeNameData
	local mapInfo = TribeNames.getMapInfo(mapType)
	if mapInfo ~= nil then
		local themeNames = if mapInfo.themes ~= nil and #mapInfo.themes > 0 then mapInfo.themes else { "default" }
		local prefixes, suffixes = {}, {}
		for _, themeName in themeNames do
			local theme = themes[themeName]
			if theme ~= nil then
				table.move(theme.prefixes, 1, #theme.prefixes, #prefixes + 1, prefixes)
				table.move(theme.suffixes, 1, #theme.suffixes, #suffixes + 1, suffixes)
			end
		end
		if #prefixes == 0 or #suffixes == 0 then
			local default = themes.default
			table.move(default.prefixes, 1, #default.prefixes, #prefixes + 1, prefixes)
			table.move(default.suffixes, 1, #default.suffixes, #suffixes + 1, suffixes)
		end
		return {
			prefixes = prefixes,
			suffixes = suffixes,
			customTribes = if mapInfo.customTribes ~= nil and #mapInfo.customTribes > 0 then mapInfo.customTribes else nil,
		}
	end
	return { prefixes = themes.default.prefixes, suffixes = themes.default.suffixes }
end

return TribeNames
