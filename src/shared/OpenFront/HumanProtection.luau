--!strict
--!native
-- Ported from RoWorld 2be8efb (src/shared/Core/Rules.luau, src/shared/Core/SimAI.luau, src/shared/Core/Sim.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- Deliberate difference from OpenFront (Bruno, 2026-11-05: "make every
-- difficulty winnable"): RoWorld's AI layer on top of OpenFront's nation AI.
-- Each part has its own gameConfig flag, and with all four off (the default,
-- and every parity trace) this module draws no random numbers and changes
-- nothing.
--   humanGrace     no nation opens a war on a human for 5 / 3 / 2 minutes of
--                  play, plus its own 0-90 s, plus up to 2 minutes for distance
--   humanWarLimit  at most 1 / 2 / 3 nations at war with one human at once
--   humanSkip      a nation passes a human over 75 % / 25 % / 0 % of the time:
--                  OpenFront's shouldAttack odds, rolled once per nation per
--                  attack cycle as in RoWorld rather than once per attempt
--   capitulation   after 20 minutes a nation under 2 % of the land surrenders
--                  to an attacker with 8x its troops, at most one per 30 s
-- Tribes have none of this. A nation may always answer a human who attacks it,
-- and may reinforce a war it already has. Bombs wait 2 minutes longer than land
-- attacks and always respect the war limit.

local GameTypes = require(script.Parent.GameTypes)
local PseudoRandom = require(script.Parent.PseudoRandom)
local Util = require(script.Parent.Util)

local Difficulty = GameTypes.Difficulty
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

local HumanProtection = {}

-- Easy, Medium and Hard are RoWorld's Relaxed, Standard and Brutal. RoWorld has
-- no Impossible; it takes Brutal's values (Bruno, 2026-11-05).
HumanProtection.GRACE_TICKS = table.freeze({
	[Difficulty.Easy] = 3000,
	[Difficulty.Medium] = 1800,
	[Difficulty.Hard] = 1200,
	[Difficulty.Impossible] = 1200,
})
HumanProtection.MAX_WARS = table.freeze({
	[Difficulty.Easy] = 1,
	[Difficulty.Medium] = 2,
	[Difficulty.Hard] = 3,
	[Difficulty.Impossible] = 3,
})
HumanProtection.SKIP_CHANCE = table.freeze({
	[Difficulty.Easy] = 0.75,
	[Difficulty.Medium] = 0.25,
	[Difficulty.Hard] = 0,
	[Difficulty.Impossible] = 0,
})
HumanProtection.GRACE_JITTER = 900
HumanProtection.GRACE_NEAR = 40 -- tiles of the 1024 x 512 grid RoWorld tuned this on
HumanProtection.GRACE_PER_TILE = 3
HumanProtection.GRACE_MAX_EXTRA = 1200
HumanProtection.NUKE_EXTRA = 1200
HumanProtection.CAPITULATE_AGE = 12000
HumanProtection.CAPITULATE_SHARE = 0.02
HumanProtection.CAPITULATE_RATIO = 8
HumanProtection.CAPITULATE_GAP = 300

-- Full-size tiles per tile of that grid: Rules.LEGACY_LIN at RoWorld's K_LIN = 1.
local GRID_TILES = 2000 / 1024

type NationState = {
	jitter: number,
	random: PseudoRandom.PseudoRandom,
	skipTick: number,
	skips: { [any]: boolean },
}

type State = {
	nations: { [any]: NationState },
	pending: { [any]: { [any]: number } },
	lastCapitulation: number,
}

local function stateOf(game: any): State
	local state = game._humanProtection
	if state == nil then
		state = { nations = {}, pending = {}, lastCapitulation = -math.huge }
		game._humanProtection = state
	end
	return state
end

local function nationStateOf(game: any, nation: any): NationState
	local state = stateOf(game)
	local entry = state.nations[nation]
	if entry == nil then
		-- Its own stream, so that this layer leaves the nation's own draws alone.
		local random = PseudoRandom.new(Util.simpleHash(nation:id()) + 7919)
		entry = {
			jitter = random:nextInt(0, HumanProtection.GRACE_JITTER + 1),
			random = random,
			skipTick = -1,
			skips = {},
		}
		state.nations[nation] = entry
	end
	return entry
end

local function isNationAgainstHuman(nation: any, human: any): boolean
	return nation:type() == PlayerType.Nation and human:isPlayer() and human:type() == PlayerType.Human
end

-- Turns on all four parts. Humans vs Nations stays OpenFront's: nations are
-- meant to come for the humans there, and the source's own shouldAttack exempts
-- that mode from its odds too.
function HumanProtection.enable(config: { [string]: any })
	if config.playerTeams == GameTypes.HumansVsNations then
		return
	end
	config.humanGrace = true
	config.humanWarLimit = true
	config.humanSkip = true
	config.capitulation = true
end

-- How many ticks of play this nation must wait before opening a war on `human`.
function HumanProtection.graceFor(game: any, nation: any, human: any): number
	local difficulty = game:config():gameConfig().difficulty
	local grace = HumanProtection.GRACE_TICKS[difficulty] + nationStateOf(game, nation).jitter
	local a, b = nation:spawnTile(), human:spawnTile()
	if a ~= nil and b ~= nil then
		local dist = math.floor(math.sqrt(game:euclideanDistSquared(a, b)) / GRID_TILES)
		grace += math.clamp(
			(dist - HumanProtection.GRACE_NEAR) * HumanProtection.GRACE_PER_TILE,
			0,
			HumanProtection.GRACE_MAX_EXTRA
		)
	end
	return grace
end

local function boatAimedAt(game: any, nation: any, human: any): boolean
	for _, boat in nation:units(UnitType.TransportShip) do
		local tile = boat:targetTile()
		if tile ~= nil and game:owner(tile) == human then
			return true
		end
	end
	return false
end

local function isAttacking(from: any, target: any): boolean
	for _, attack in from:outgoingAttacks() do
		if attack:target() == target then
			return true
		end
	end
	return false
end

-- Nations at war with `human`: their attacks on it, boats sailing for it and
-- this tick's orders, which only start at the end of the tick (without them two
-- nations deciding on one tick could both slip under the limit). An answer to
-- the human's own attack isn't a war it has to be protected from (RoWorld's
-- a.counter).
function HumanProtection.warsOn(game: any, human: any): number
	local seen: { [any]: boolean } = {}
	local count = 0
	local function add(nation: any)
		if not seen[nation] then
			seen[nation] = true
			count += 1
		end
	end
	for _, attack in human:incomingAttacks() do
		local attacker = attack:attacker()
		if attacker:type() == PlayerType.Nation and not isAttacking(human, attacker) then
			add(attacker)
		end
	end
	for _, boat in game:units(UnitType.TransportShip) do
		local owner = boat:owner()
		if owner:type() == PlayerType.Nation then
			local tile = boat:targetTile()
			if tile ~= nil and game:owner(tile) == human then
				add(owner)
			end
		end
	end
	local pending = stateOf(game).pending[human]
	if pending ~= nil then
		local now = game:ticks()
		for nation, tick in pending do
			if tick == now then
				add(nation)
			end
		end
	end
	return count
end

local function mayOpenWar(game: any, nation: any, human: any, ageOffset: number): boolean
	local config = game:config():gameConfig()
	if config.humanGrace and game:_ticksSinceStart() - ageOffset < HumanProtection.graceFor(game, nation, human) then
		return false
	end
	if config.humanWarLimit and HumanProtection.warsOn(game, human) >= HumanProtection.MAX_WARS[config.difficulty] then
		return false
	end
	return true
end

-- May this nation not start on this human? A war it already has is exempt.
function HumanProtection.offLimits(game: any, nation: any, human: any): boolean
	local config = game:config():gameConfig()
	if not (config.humanGrace or config.humanWarLimit) or not isNationAgainstHuman(nation, human) then
		return false
	end
	if isAttacking(nation, human) or boatAimedAt(game, nation, human) then
		return false
	end
	return not mayOpenWar(game, nation, human, 0)
end

-- Bombs wait NUKE_EXTRA longer and, as in RoWorld, get no exemption for a war
-- the nation already has.
function HumanProtection.nukeOffLimits(game: any, nation: any, human: any): boolean
	local config = game:config():gameConfig()
	if not (config.humanGrace or config.humanWarLimit) or not isNationAgainstHuman(nation, human) then
		return false
	end
	return not mayOpenWar(game, nation, human, HumanProtection.NUKE_EXTRA)
end

-- One roll per nation per human per attack cycle (a nation acts on one tick of
-- each cycle), so the odds aren't diluted by the several strategies that can
-- pick the same target. A war it already has is never skipped.
function HumanProtection.skips(game: any, nation: any, human: any): boolean
	if isAttacking(nation, human) or boatAimedAt(game, nation, human) then
		return false
	end
	local entry = nationStateOf(game, nation)
	local now = game:ticks()
	if entry.skipTick ~= now then
		entry.skipTick = now
		table.clear(entry.skips)
	end
	local rolled = entry.skips[human]
	if rolled == nil then
		local chance = HumanProtection.SKIP_CHANCE[game:config():gameConfig().difficulty]
		rolled = entry.random:next() < chance
		entry.skips[human] = rolled
	end
	return rolled
end

-- Records an order on a human, for warsOn.
function HumanProtection.noteWar(game: any, nation: any, target: any)
	if not game:config():gameConfig().humanWarLimit or not isNationAgainstHuman(nation, target) then
		return
	end
	local state = stateOf(game)
	local pending = state.pending[target]
	if pending == nil then
		pending = {}
		state.pending[target] = pending
	end
	pending[nation] = game:ticks()
end

-- All of `loser`'s land to `winner`, wherever it lies. Its gold follows
-- OpenFront's conquest rule, and its structures are captured by the next
-- PlayerExecution tick as with any land lost.
function HumanProtection.surrender(game: any, loser: any, winner: any)
	stateOf(game).lastCapitulation = game:ticks()
	game:conquerPlayer(winner, loser)
	game:displayMessage("events_display.surrendered_to_you", "CONQUERED_PLAYER", winner:id(), nil, {
		name = loser:displayName(),
	})
	for _, tile in table.clone(loser:tiles():values()) do
		winner:conquer(tile)
	end
end

-- Endgame, once per attack cycle: a small nation overrun by a far stronger
-- attacker gives up. True if it did.
function HumanProtection.considerCapitulation(game: any, nation: any): boolean
	if not game:config():gameConfig().capitulation or nation:type() ~= PlayerType.Nation then
		return false
	end
	if game:_ticksSinceStart() < HumanProtection.CAPITULATE_AGE then
		return false
	end
	if nation:numTilesOwned() >= HumanProtection.CAPITULATE_SHARE * game:totalLandTiles() then
		return false
	end
	if game:ticks() - stateOf(game).lastCapitulation < HumanProtection.CAPITULATE_GAP then
		return false
	end
	local mine = nation:troops() + 1
	for _, attack in nation:incomingAttacks() do
		local attacker = attack:attacker()
		if attacker:type() ~= PlayerType.Bot and attacker:troops() + attack:troops() >= HumanProtection.CAPITULATE_RATIO * mine then
			HumanProtection.surrender(game, nation, attacker)
			return true
		end
	end
	return false
end

return HumanProtection
