--!strict
-- Ported from OpenFront v0.35.2 (src/client/view/PlayerColors.ts; src/client/theme/ThemeProvider.ts; src/client/theme/ColorAllocator.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Math = require(script.Parent.ColorMath)
local Js = require(script.Parent.JsMath)
local Themes = require(script.Parent.Themes)
export type Color = Math.Color
type Settings = typeof(Themes.default)
type Allocator = {available: {Color}, fallback: {Color}, assigned: {[string]: Color}, order: {Color}}
export type Theme = {settings: Settings, human: Allocator, nation: Allocator, bot: Allocator,
	teamPalettes: {[string]: {Color}}, teamPlayerColors: {[string]: Color}, useClassicBotColors: boolean}
export type Cosmetics = {color: {color: string}?, pattern: {colorPalette: {primaryColor: string, secondaryColor: string}?}?}
local PlayerColors = {}

-- Original: ColorAllocator.constructor (fallback includes the original pool).
local function allocator(colors: {string}, fallback: {string}): Allocator
	local available, all = {}, {}
	for _, hex in colors do local c = Math.fromHex(hex); table.insert(available, c); table.insert(all, c) end
	for _, hex in fallback do table.insert(all, Math.fromHex(hex)) end
	return {available = available, fallback = all, assigned = {}, order = {}}
end

-- Original: ColorAllocator.selectDistinctColorIndex / minDeltaE.
function PlayerColors.selectDistinctColorIndex(available: {Color}, assigned: {Color}): number
	assert(#assigned > 0, "No assigned colors")
	local maximum, index = 0, 1
	for i, color in available do
		local minimum = math.huge
		for _, previous in assigned do minimum = math.min(minimum, Math.delta(color, previous)) end
		if minimum > maximum then maximum, index = minimum, i end
	end
	return index -- Luau array index; source's returned index is one lower.
end

-- Original: ColorAllocator.assignColor. Explicit order mirrors JS Map.
local function assignColor(s: Allocator, id: string): Color
	local old = s.assigned[id]
	if old then return old end
	if #s.available == 0 then s.available = table.clone(s.fallback) end
	local index = if #s.order == 0 or #s.order > 50 then Js.seededInt(Js.simpleHash(id), 0, #s.available) + 1
		else PlayerColors.selectDistinctColorIndex(s.available, s.order)
	local c = table.remove(s.available, index) :: Color
	s.assigned[id] = c; table.insert(s.order, c)
	return c
end

-- Original: ThemeProvider.generateTeamColors.
function PlayerColors.generateTeamColors(base: Color): {Color}
	local lch = Math.toLch(base)
	local result = {base}
	for i = 1, 63 do
		local h = (lch.h + ((i * 137.508) % 12) - 6 + 360) % 360
		local c = math.clamp(lch.c * (1 + .1 * math.sin(i * .7)), 10, 130)
		local l = math.clamp(lch.l + 18 * math.sin(i * 137.508 * (math.pi / 180)), 25, 80)
		table.insert(result, Math.fromLch({l = l, c = c, h = h, a = 1}))
	end
	return result
end

-- Original: ThemeProvider.buildTeamPalettes.
function PlayerColors.buildTeamPalettes(settings: Settings): {[string]: {Color}}
	local teams: {[string]: {Color}} = {}
	for team, hex in settings.teamColors :: {[string]: string} do
		local base = Math.fromHex(hex)
		teams[team] = if team == "Bot" then {base} else PlayerColors.generateTeamColors(base)
	end
	return teams
end

-- Original: SettingsTheme.constructor / buildTeamPalettes. Construct once per
-- match; caller owns lifecycle and never changes confirmed gameplay IDs.
function PlayerColors.new(palette: string?): Theme
	local settings = (Themes :: {[string]: Settings})[palette or "default"]
	assert(settings, "unknown OpenFront palette")
	local teams = PlayerColors.buildTeamPalettes(settings)
	return {settings = settings, human = allocator(settings.humanColors, settings.fallbackColors),
		nation = allocator(settings.nationColors, settings.nationColors), bot = allocator(settings.classicBotColors, settings.classicBotColors),
		teamPalettes = teams, teamPlayerColors = {}, useClassicBotColors = false}
end

-- Original: SettingsTheme.focusedBorderColor.
function PlayerColors.focusedBorderColor(theme: Theme): Color
	return Math.fromHex(theme.settings.focusedBorderColor)
end

-- Original: SettingsTheme.spawnHighlightColor.
function PlayerColors.spawnHighlightColor(theme: Theme): Color
	return Math.fromHex(theme.settings.spawnHighlightColor)
end

-- Original: SettingsTheme.teamColorVariations.
local function teamColors(theme: Theme, team: string): {Color}
	return theme.teamPalettes[team] or {assignColor(theme.human, team)}
end

-- Original: SettingsTheme.teamColorForPlayer (cache keyed by ID, as source).
function PlayerColors.teamColorForPlayer(theme: Theme, team: string, id: string): Color
	local cached = theme.teamPlayerColors[id]
	if cached then return cached end
	local colors = teamColors(theme, team)
	local color = colors[Js.simpleHash(id) % #colors + 1]
	theme.teamPlayerColors[id] = color
	return color
end

-- Original: SettingsTheme.teamColor (rounded RGB).
function PlayerColors.teamColor(theme: Theme, team: string): Color
	return Math.toRgb(teamColors(theme, team)[1])
end

-- Original: SettingsTheme.territoryColor. Nations use the nation palette,
-- not tribe grey. There is no player-index modulo palette assignment.
function PlayerColors.territoryColor(theme: Theme, id: string, playerType: string, team: string?): Color
	if team then return PlayerColors.teamColorForPlayer(theme, team, id) end
	if playerType == "HUMAN" then return assignColor(theme.human, id) end
	if playerType == "BOT" then
		return if theme.useClassicBotColors then assignColor(theme.bot, id) else PlayerColors.teamColorForPlayer(theme, "Bot", id)
	end
	return assignColor(theme.nation, id)
end

-- Original: SettingsTheme.borderColor. Lightness scale uses rounded toHsl,
-- then absolute darkening uses unrounded rgbaToHsla, matching Colord.
function PlayerColors.borderColor(theme: Theme, territory: Color): Color
	local color = territory
	if theme.settings.borderLightnessScale ~= 1 then
		local hsl = Math.toHsl(color, true); hsl.l *= theme.settings.borderLightnessScale
		color = Math.fromHsl(hsl)
	end
	if theme.settings.borderDarken ~= 0 then color = Math.darken(color, theme.settings.borderDarken) end
	return color
end

-- Original: PlayerColors.resolvePlayerColors. Cosmetic primary doesn't
-- override team fill; pattern secondary wins even for the focused player.
function PlayerColors.resolvePlayerColors(theme: Theme, themed: Color, cosmetics: Cosmetics, team: string?, focused: boolean): {territory: Color, border: Color}
	local border = PlayerColors.borderColor(theme, themed)
	local palette = if cosmetics.pattern then cosmetics.pattern.colorPalette or {
		primaryColor = Math.toHex(themed), secondaryColor = Math.toHex(border)} else nil
	local color = if cosmetics.color then cosmetics.color.color else nil
	local territory = if team then themed else Math.fromHex(color or (if palette then palette.primaryColor else Math.toHex(themed)))
	local edge = Math.fromHex((if palette then palette.secondaryColor else nil) or color
		or (if focused then theme.settings.focusedBorderColor else Math.toHex(border)))
	return {territory = territory, border = edge}
end

-- Original: SettingsTheme.defendedBorderColors (helper, distinct from shader checker).
function PlayerColors.defendedBorderColors(theme: Theme, territory: Color): {light: Color, dark: Color}
	return {light = Math.darken(territory, theme.settings.defendedBorderDarkenLight),
		dark = Math.darken(territory, theme.settings.defendedBorderDarkenDark)}
end

-- Original: SettingsTheme.structureColors, including >10/>50 loop bounds.
function PlayerColors.structureColors(theme: Theme, territory: Color): {light: Color, dark: Color}
	local lightInput = table.clone(territory); lightInput.a = 150 / 255
	local light, dark = Math.toLab(lightInput, true), Math.toLab(PlayerColors.borderColor(theme, territory), true)
	local loops = 0
	while Math.delta(Math.fromLab(light), Math.fromLab(dark)) < theme.settings.structureContrastTarget do
		if loops > 50 then break
		elseif loops > 10 then light.l = math.clamp(light.l + 5, 0, 100)
		else dark.l = math.clamp(dark.l - 5, 0, 100) end
		loops += 1
	end
	return {light = Math.fromLab(light), dark = Math.fromLab(dark)}
end

return PlayerColors
