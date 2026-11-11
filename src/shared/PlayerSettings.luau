--!strict
-- The player's settings (the Settings dialog; saved in their profile). Pure.

local PlayerSettings = {}

export type Settings = {
	-- Music on or muted (the sound buttons' slash); musicVolume is the
	-- Settings slider (Bruno, 2026-10-28), 0..1 in steps of 0.05. Dragging it
	-- to 0 mutes, above 0 unmutes.
	music: boolean,
	musicVolume: number,
	sounds: boolean,
	uiScale: number, -- 0.8 .. 1.25
	emojis: boolean, -- show other players' emoji over their names
	-- A tap on another player's land opens the attack card instead of
	-- attacking (Bruno, 2026-10-28; OpenFront's leftClickOpensMenu).
	selectBeforeAttack: boolean,
	-- Nation names on the map (Bruno, 2026-10-28, after RoWorld).
	territoryLabels: boolean,
	-- The pops while your land grows (Bruno, 2026-10-30): "pop" (UI Cute
	-- Pop), "suction" (Suction Pop 4) or "off".
	expandSound: string,
}

PlayerSettings.UI_SCALES = { 0.8, 0.9, 1, 1.1, 1.25 }
PlayerSettings.EXPAND_SOUNDS = { "pop", "suction", "off" }

function PlayerSettings.defaults(): Settings
	return { music = true, musicVolume = 0.5, sounds = true, uiScale = 1, emojis = true, selectBeforeAttack = true, territoryLabels = true, expandSound = "pop" }
end

-- A clean copy of whatever a client or an old save sends.
function PlayerSettings.sanitize(raw: any): Settings
	local out = PlayerSettings.defaults()
	if type(raw) ~= "table" then
		return out
	end
	if type(raw.music) == "boolean" then
		out.music = raw.music
	end
	if type(raw.sounds) == "boolean" then
		out.sounds = raw.sounds
	end
	if type(raw.emojis) == "boolean" then
		out.emojis = raw.emojis
	end
	if type(raw.selectBeforeAttack) == "boolean" then
		out.selectBeforeAttack = raw.selectBeforeAttack
	end
	if type(raw.territoryLabels) == "boolean" then
		out.territoryLabels = raw.territoryLabels
	end
	if type(raw.expandSound) == "string" and table.find(PlayerSettings.EXPAND_SOUNDS, raw.expandSound) then
		out.expandSound = raw.expandSound
	end
	if type(raw.musicVolume) == "number" and raw.musicVolume == raw.musicVolume then
		out.musicVolume = math.clamp(math.round(raw.musicVolume * 20) / 20, 0, 1)
	end
	if type(raw.uiScale) == "number" and raw.uiScale == raw.uiScale then
		local best = 1
		for _, s in PlayerSettings.UI_SCALES do
			if math.abs(s - raw.uiScale) < math.abs(best - raw.uiScale) then
				best = s
			end
		end
		out.uiScale = best
	end
	return out
end

return PlayerSettings
