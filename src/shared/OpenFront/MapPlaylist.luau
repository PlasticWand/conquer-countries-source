--!strict
-- Ported from OpenFront v0.35.2 (src/server/MapPlaylist.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The public lobbies' game configs: which map comes next and with what
-- settings, for "ffa" and "team" games.
--   - Playlists hold each map as many times as its frequency (per-mode
--     frequency when >= 0, else multiplayerFrequency), shuffled with no map
--     repeating within 5 games (addNextMapNonConsecutive).
--   - Every third game of a queue is compact (when a team game allows it).
--   - Team games roll a team count from TEAM_WEIGHTS (special team maps
--     force theirs 75% of the time).
--   - Lobby size comes from the map's land tiles (calculateMapPlayerCounts).
-- Conquest differences: only maps imported into this place are eligible
-- (`available`); the "special" queue (modifiers), trusted lobbies and API
-- weight overrides are not ported. Randomness is injected (`random` for
-- Math.random, `seed` for the shuffle's PseudoRandom(Date.now())).

local GameTypes = require(script.Parent.GameTypes)
local MapInfo = require(script.Parent.Data.MapInfo) :: { any }
local PseudoRandom = require(script.Parent.PseudoRandom)

local Duos, Trios, Quads, HumansVsNations = GameTypes.Duos, GameTypes.Trios, GameTypes.Quads, GameTypes.HumansVsNations

local MapPlaylist = {}
MapPlaylist.__index = MapPlaylist

local TEAM_WEIGHTS: { { config: any, weight: number } } = {
	{ config = 2, weight = 10 },
	{ config = 3, weight = 10 },
	{ config = 4, weight = 10 },
	{ config = 5, weight = 10 },
	{ config = 6, weight = 10 },
	{ config = 7, weight = 10 },
	{ config = Duos, weight = 5 },
	{ config = Trios, weight = 7.5 },
	{ config = Quads, weight = 7.5 },
	{ config = HumansVsNations, weight = 20 },
}
local SPECIAL_TEAM_FORCE_CHANCE = 0.75
local NON_CONSECUTIVE = 5

export type Available = { [string]: { landTiles: number } } -- by GameMapType

export type MapPlaylist = typeof(setmetatable(
	{} :: {
		available: Available,
		random: () -> number,
		seed: () -> number,
		playlists: { [string]: { string } },
		compact: boolean,
	},
	MapPlaylist
))

-- `options.compact` (default true, OpenFront's rule): every 3rd game of a
-- playlist is on the compact (quarter-area) map. Conquest turns it off for
-- public lobbies (Bruno, 2026-11-03: ranges stay the same in tiles, so on a
-- compact map SAM, defense and nuke circles looked twice as big).
function MapPlaylist.new(available: Available, random: () -> number, seed: () -> number, options: { compact: boolean? }?): MapPlaylist
	local compact = if options and options.compact == false then false else true
	return setmetatable({ available = available, random = random, seed = seed, playlists = { ffa = {}, team = {} }, compact = compact }, MapPlaylist)
end

local function infoOf(mapType: string): any
	for _, m in MapInfo do
		if m.type == mapType then
			return m
		end
	end
	return nil
end

function MapPlaylist._buildMapsList(self: MapPlaylist, kind: string): { string }
	local maps = {}
	for _, m in MapInfo do
		if self.available[m.type] == nil then
			continue
		end
		local freq
		if kind == "ffa" then
			freq = if m.ffaFrequency >= 0 then m.ffaFrequency else m.multiplayerFrequency
		else
			freq = if m.teamFrequency >= 0 then m.teamFrequency else m.multiplayerFrequency
		end
		for _ = 1, freq do
			table.insert(maps, m.type)
		end
	end
	-- Conquest: with few maps imported, a map whose frequencies are all 0
	-- would leave the queue empty; such queues fall back to every map once.
	if #maps == 0 then
		for _, m in MapInfo do
			if self.available[m.type] then
				table.insert(maps, m.type)
			end
		end
	end
	return maps
end

local function addNextMapNonConsecutive(playlist: { string }, source: { string }): boolean
	local last = {}
	for i = math.max(1, #playlist - NON_CONSECUTIVE + 1), #playlist do
		last[playlist[i]] = true
	end
	for i, map in source do
		if not last[map] then
			table.remove(source, i)
			table.insert(playlist, map)
			return true
		end
	end
	return false
end

function MapPlaylist._generateNewPlaylist(self: MapPlaylist, kind: string): { string }
	local maps = self:_buildMapsList(kind)
	local rand = PseudoRandom.new(self.seed())
	local playlist = {}
	for _ = 1, 10000 do
		table.clear(playlist)
		local source = rand:shuffleArray(maps)
		local ok = true
		while #source > 0 do
			if not addNextMapNonConsecutive(playlist, source) then
				ok = false
				break
			end
		end
		if ok then
			return playlist
		end
	end
	return rand:shuffleArray(maps)
end

function MapPlaylist.nextMap(self: MapPlaylist, kind: string): string
	local playlist = self.playlists[kind]
	if #playlist == 0 then
		for _, m in self:_generateNewPlaylist(kind) do
			table.insert(playlist, m)
		end
	end
	return table.remove(playlist, 1) :: string
end

function MapPlaylist._getTeamCount(self: MapPlaylist, mapType: string): any
	local info = infoOf(mapType)
	if info and info.specialTeamCount ~= nil and self.random() < SPECIAL_TEAM_FORCE_CHANCE then
		return info.specialTeamCount
	end
	local total = 0
	for _, w in TEAM_WEIGHTS do
		total += w.weight
	end
	local roll = self.random() * total
	local cumulative = 0
	for _, w in TEAM_WEIGHTS do
		cumulative += w.weight
		if roll < cumulative then
			return w.config
		end
	end
	return TEAM_WEIGHTS[1].config
end

local function roundToNearest5(n: number): number
	return math.floor(n / 5 + 0.5) * 5
end

-- [large, medium, small]: 50 players per million land tiles, then 75% and 50%.
function MapPlaylist.calculateMapPlayerCounts(landTiles: number): (number, number, number)
	local base = math.max(roundToNearest5(landTiles / 1_000_000 * 50), 5)
	return base, roundToNearest5(base * 0.75), roundToNearest5(base * 0.5)
end

function MapPlaylist._lobbyMaxPlayers(self: MapPlaylist, mapType: string, team: boolean, compact: boolean?): number
	local l, m, s = MapPlaylist.calculateMapPlayerCounts(self.available[mapType].landTiles)
	local r = self.random()
	local base = if r < 0.3 then l elseif r < 0.6 then m else s
	local p = math.min(if team then math.ceil(base * 1.5) else base, l)
	if compact then
		p = math.max(3, math.floor(p * 0.25))
	end
	return p
end

function MapPlaylist.adjustForTeams(playerCount: number, teams: any): number
	if teams == nil then
		return playerCount
	end
	local p = playerCount
	if teams == Duos then
		p -= p % 2
	elseif teams == Trios then
		p -= p % 3
	elseif teams == Quads then
		p -= p % 4
	elseif teams == HumansVsNations then
		p = math.floor(p / 2)
	else
		p -= p % teams
	end
	return p
end

local function playersPerTeam(count: number, teams: any): number
	if teams == Duos then
		return math.min(2, count)
	elseif teams == Trios then
		return math.min(3, count)
	elseif teams == Quads then
		return math.min(4, count)
	elseif teams == HumansVsNations then
		return count
	end
	return math.floor(count / teams)
end

local function numberOfTeams(count: number, teams: any): number
	if teams == Duos then
		return math.floor(count / 2)
	elseif teams == Trios then
		return math.floor(count / 3)
	elseif teams == Quads then
		return math.floor(count / 4)
	elseif teams == HumansVsNations then
		return 2
	end
	return teams
end

local function supportsTeamPlayerCount(count: number, teams: any): boolean
	return playersPerTeam(count, teams) >= 2 and numberOfTeams(count, teams) >= 2
end

function MapPlaylist._supportsCompactMapForTeams(self: MapPlaylist, mapType: string, teams: any): boolean
	local l, _, s = MapPlaylist.calculateMapPlayerCounts(self.available[mapType].landTiles)
	local p = math.min(math.ceil(s * 1.5), l)
	p = math.max(3, math.floor(p * 0.25))
	p = MapPlaylist.adjustForTeams(p, teams)
	return supportsTeamPlayerCount(p, teams)
end

local function adjustTeamCountForPlayerCapacity(teams: any, unadjusted: number): any
	if type(teams) ~= "number" or supportsTeamPlayerCount(MapPlaylist.adjustForTeams(unadjusted, teams), teams) then
		return teams
	end
	return math.max(2, math.floor(unadjusted / 2))
end

-- getSpawnImmunityDuration without starting-gold modifiers: 5 s.
local function spawnImmunityDuration(_teams: any): number
	return 5 * 10
end

-- MapPlaylist.rollConfig for "ffa" or "team": an OpenFront GameConfig.
-- Conquest: `forcedMap` pins the map (the always-on World queue); it then
-- leaves the playlist alone and is never compact.
function MapPlaylist.gameConfig(self: MapPlaylist, kind: "ffa" | "team", forcedMap: string?): { [string]: any }
	local team = kind == "team"
	local map = forcedMap or self:nextMap(kind)
	local playerTeams = if team then self:_getTeamCount(map) else nil
	local compact = self.compact and forcedMap == nil and #self.playlists[kind] % 3 == 0
	if compact and team and not self:_supportsCompactMapForTeams(map, playerTeams) then
		compact = false
	end
	local unadjusted = self:_lobbyMaxPlayers(map, team, compact)
	playerTeams = adjustTeamCountForPlayerCapacity(playerTeams, unadjusted)
	return {
		donateGold = team,
		donateTroops = team,
		gameMap = map,
		maxPlayers = MapPlaylist.adjustForTeams(unadjusted, playerTeams),
		gameType = "Public",
		gameMapSize = if compact then "Compact" else "Normal",
		publicGameModifiers = { isCompact = if compact then true else nil },
		difficulty = if playerTeams == HumansVsNations then "Hard" else "Medium",
		infiniteGold = false,
		infiniteTroops = false,
		instantBuild = false,
		randomSpawn = false,
		nations = if team and playerTeams ~= HumansVsNations then "disabled" else "default",
		gameMode = if team then "Team" else "Free For All",
		playerTeams = playerTeams,
		bots = if compact then 100 else 400,
		spawnImmunityDuration = spawnImmunityDuration(playerTeams),
		disabledUnits = {},
		disableClanTags = if team then nil else true,
		overtime = if team then nil else { enabled = true },
	}
end

return MapPlaylist
