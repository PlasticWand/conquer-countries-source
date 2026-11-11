--!strict
-- Words and numbers for the menus (docs/design/rofront-ui-pass.md). Pure.
--   - The solo difficulty sentence, from OpenFront's own difficulty strings
--     ("{smarts}, {troops}") and Config's nation multipliers (max troops
--     and growth); tests check the numbers against Config.
--   - Public match rows: "Next: Black Sea • 41/50 players • starts in 0:44".

local OF = script.Parent.OpenFront
local Lang = require(OF.Lang)

local MenuModel = {}

MenuModel.DIFFICULTIES = { "Easy", "Medium", "Hard", "Impossible" }

-- Config.maxTroops / Config.troopIncreaseRate for nations, by difficulty.
MenuModel.NATION_TROOPS = { Easy = 0.5, Medium = 0.75, Hard = 1, Impossible = 1.25 }
MenuModel.NATION_GROWTH = { Easy = 0.9, Medium = 0.95, Hard = 1, Impossible = 1.05 }

-- What the nation AI does differently (AiAttackBehavior, Nation*Behavior).
local BEHAVIOUR = {
	Easy = "They often skip attacks and never retaliate.",
	Medium = "They retaliate when you attack them.",
	Hard = "They retaliate, prey on weak neighbours and aim nukes around your SAMs.",
	Impossible = "They also hunt your SAMs and aim nukes at your structures.",
}

function MenuModel.difficultyName(d: string): string
	return Lang.t("difficulty." .. string.lower(d))
end

-- "Dumb, 50% of a human's max troops. They rarely attack, ..."
function MenuModel.difficultyText(d: string): string
	local key = string.lower(d)
	local troops = MenuModel.NATION_TROOPS[d]
	local troopsText = if troops == 1
		then Lang.t("difficulty.info_troops_same")
		else Lang.t("difficulty.info_troops", { percent = math.floor(troops * 100 + 0.5) })
	local info = Lang.t("difficulty.info", { smarts = Lang.t("difficulty.info_smarts_" .. key), troops = troopsText })
	return `{info}. {BEHAVIOUR[d] or ""}`
end

-- "Next: Black Sea • 41/50 players • starts in 0:44"
function MenuModel.lobbyLine(lobby: { mapName: string?, players: number, capacity: number, seconds: number?, mode: string? }, showMap: boolean): string
	local parts = {}
	if showMap and lobby.mapName then
		table.insert(parts, `Next: {lobby.mapName}`)
	end
	if lobby.mode and lobby.mode ~= "" then
		table.insert(parts, lobby.mode)
	end
	table.insert(parts, `{lobby.players} / {lobby.capacity} players`)
	if lobby.seconds then
		local s = math.max(0, math.floor(lobby.seconds))
		table.insert(parts, `starts in {s // 60}:{string.format("%02d", s % 60)}`)
	end
	return table.concat(parts, "  •  ")
end

return MenuModel
