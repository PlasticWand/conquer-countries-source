--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/nation/NationUtils.ts and engine-lib/src/Util.ts calculateBoundingBox), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Helpers shared by the nation behaviours: saving up for purchases, random
-- own tiles, the juiciest target and the runaway leader.

local GameTypes = require(script.Parent.Parent.Parent.GameTypes)

local Difficulty = GameTypes.Difficulty
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

local NationUtils = {}

-- Starting gold from which nations place many structures at once.
local HIGH_STARTING_GOLD = 3_000_000

function NationUtils.hasHighStartingGold(game: any, player: any): boolean
	return game:config():startingGold(player:info()) >= HIGH_STARTING_GOLD
end

-- Most minutes of income worth saving up for, by difficulty.
local SAVE_UP_HORIZON_MINUTES = {
	[Difficulty.Easy] = math.huge,
	[Difficulty.Medium] = math.huge,
	[Difficulty.Hard] = 5,
	[Difficulty.Impossible] = 6,
}

-- Whether `target` gold is close enough to save up for at current income.
function NationUtils.isSaveUpWithinReach(game: any, player: any, target: number): boolean
	local horizon = SAVE_UP_HORIZON_MINUTES[game:config():gameConfig().difficulty]
	local missing = target - player:gold()
	if horizon == math.huge or missing <= 0 then
		return true
	end
	-- Income grows about linearly, so the current rate is about twice the average.
	local minutes = math.max(1, game:ticks() / 600)
	local incomePerMinute = (2 * player:goldEarned()) / minutes
	return missing <= incomePerMinute * horizon
end

-- Util.ts calculateBoundingBox over a list of tiles.
function NationUtils.calculateBoundingBox(gm: any, tiles: { number }): { min: { x: number, y: number }, max: { x: number, y: number } }
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, t in tiles do
		local x, y = gm:x(t), gm:y(t)
		minX, minY = math.min(minX, x), math.min(minY, y)
		maxX, maxY = math.max(maxX, x), math.max(maxY, y)
	end
	return { min = { x = minX, y = minY }, max = { x = maxX, y = maxY } }
end

-- calculateBoundingBox(p.borderTiles()), read in place: copying every border
-- tile per call made the nations' random territory samples a tick cost.
function NationUtils.borderBoundingBox(gm: any, p: any): { min: { x: number, y: number }, max: { x: number, y: number } }
	local minX, minY, maxX, maxY = p:borderTiles():boundingBox(gm:width())
	return { min = { x = minX, y = minY }, max = { x = maxX, y = maxY } }
end

local function randTerritoryTile(random: any, mg: any, p: any, box: any): number?
	box = box or NationUtils.borderBoundingBox(mg, p)
	for _ = 1, 100 do
		local x = random:nextInt(box.min.x, box.max.x)
		local y = random:nextInt(box.min.y, box.max.y)
		if mg:isValidCoord(x, y) then
			local tile = mg:ref(x, y)
			if mg:owner(tile) == p then
				return tile
			end
		end
	end
	if p:numTilesOwned() > 0 and p:numTilesOwned() <= 100 then
		return random:randElement(p:tiles():values())
	end
	return nil
end

function NationUtils.randTerritoryTileArray(random: any, mg: any, player: any, numTiles: number): { number }
	local box = NationUtils.borderBoundingBox(mg, player)
	local tiles = {}
	for _ = 1, numTiles do
		local tile = randTerritoryTile(random, mg, player, box)
		if tile ~= nil then
			table.insert(tiles, tile)
		end
	end
	return tiles
end

-- The candidate with the most to take: non-defensive structures, troop-cap
-- headroom and land, each normalised over the candidates.
function NationUtils.findJuiciestTarget(game: any, candidates: { any }): any?
	if #candidates == 0 then
		return nil
	end
	local stats = {}
	for _, p in candidates do
		local structureCount = 0
		for _, u in p:units() do
			local t = u:type()
			if GameTypes.isStructure[t] and t ~= UnitType.DefensePost and t ~= UnitType.MissileSilo then
				structureCount += u:level()
			end
		end
		local maxTroops = game:config():maxTroops(p)
		table.insert(stats, {
			player = p,
			structureCount = structureCount,
			troopGapRatio = if maxTroops > 0 then 1 - p:troops() / maxTroops else 0,
			tiles = p:numTilesOwned(),
		})
	end
	local function range(key: string): (number, number)
		local lo, hi = math.huge, -math.huge
		for _, s in stats do
			lo, hi = math.min(lo, s[key]), math.max(hi, s[key])
		end
		return lo, hi
	end
	local function normalize(value: number, lo: number, hi: number): number
		return if hi > lo then (value - lo) / (hi - lo) else 0
	end
	local sLo, sHi = range("structureCount")
	local gLo, gHi = range("troopGapRatio")
	local tLo, tHi = range("tiles")
	local best, bestScore = nil, -math.huge
	for _, s in stats do
		local juiciness = normalize(s.structureCount, sLo, sHi) + normalize(s.troopGapRatio, gLo, gHi) + normalize(s.tiles, tLo, tHi)
		if juiciness > bestScore then
			bestScore = juiciness
			best = s.player
		end
	end
	return best
end

-- How many times the runner-up's land a runaway leader owns. Easy nations
-- never notice one.
local RUNAWAY_FACTOR = { [Difficulty.Medium] = 3, [Difficulty.Hard] = 2, [Difficulty.Impossible] = 1.5 }

-- The FFA player (not a tribe) with the most land, if far enough ahead.
function NationUtils.findRunawayLeader(game: any): any?
	local config = game:config():gameConfig()
	if config.gameMode ~= GameTypes.GameMode.FFA then
		return nil
	end
	local factor = RUNAWAY_FACTOR[config.difficulty]
	if factor == nil then
		return nil
	end
	local leader, runnerUp = nil, nil
	for _, p in game:players() do
		if p:type() ~= PlayerType.Bot then
			if leader == nil or p:numTilesOwned() > leader:numTilesOwned() then
				runnerUp = leader
				leader = p
			elseif runnerUp == nil or p:numTilesOwned() > runnerUp:numTilesOwned() then
				runnerUp = p
			end
		end
	end
	if leader == nil or runnerUp == nil then
		return nil
	end
	return if leader:numTilesOwned() >= runnerUp:numTilesOwned() * factor then leader else nil
end

return NationUtils
