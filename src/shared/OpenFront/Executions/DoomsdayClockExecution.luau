--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/DoomsdayClockExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Doomsday Clock (anti-stall modifier). Once a second every side (a player in
-- FFA, a whole team otherwise) must hold the rising share from DoomsdayClock.
-- A non-leading side below it is marked, then after the warn window drains
-- troops (and warship health) toward a decaying floor; once the floor bottoms
-- out its territory rots into fallout until it dies. No PRNG: tile choices
-- come from integer hashes, so the order things are visited in decides the
-- result (player tiles in TileSet order, the rot front in JS Map order).

local DoomsdayClock = require(script.Parent.Parent.DoomsdayClock)
local GameTypes = require(script.Parent.Parent.GameTypes)

local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType
local ROT_NOISE_SCALE = DoomsdayClock.ROT_NOISE_SCALE

-- LowestN: keeps the n lowest-keyed tiles offered, in key order; ties keep
-- the earlier tile.
local function lowestN(n: number)
	local tiles, keys = {}, {}
	local self = {}
	function self.offer(tile: number, key: number)
		if #tiles == n and key >= keys[#tiles] then
			return
		end
		local i = #keys
		while i > 0 and keys[i] > key do
			i -= 1
		end
		table.insert(tiles, i + 1, tile)
		table.insert(keys, i + 1, key)
		if #tiles > n then
			table.remove(tiles)
			table.remove(keys)
		end
	end
	function self.size(): number
		return #tiles
	end
	function self.take(): { number }
		return tiles
	end
	return self
end

-- The rot front: a JS Map of tile -> rotted-neighbour count. Insertion
-- ordered; set on a present key keeps its place, delete then set appends.
type Front = { order: { number | false }, slot: { [number]: number }, count: { [number]: number }, size: number }

local function newFront(): Front
	return { order = {}, slot = {}, count = {}, size = 0 }
end

local function frontSet(f: Front, tile: number, value: number)
	if f.slot[tile] == nil then
		table.insert(f.order, tile)
		f.slot[tile] = #f.order
		f.size += 1
	end
	f.count[tile] = value
end

local function frontDelete(f: Front, tile: number)
	local i = f.slot[tile]
	if i ~= nil then
		f.order[i] = false
		f.slot[tile] = nil
		f.count[tile] = nil
		f.size -= 1
	end
end

local function frontEach(f: Front, fn: (number, number) -> ())
	for _, tile in f.order do
		if tile ~= false and f.slot[tile :: number] ~= nil then
			fn(tile :: number, f.count[tile :: number])
		end
	end
end

local DoomsdayClockExecution = {}
DoomsdayClockExecution.__index = DoomsdayClockExecution

export type DoomsdayClockExecution = typeof(setmetatable(
	{} :: { active: boolean, mg: any, rotState: { [number]: { since: number, held: number, front: Front } } },
	DoomsdayClockExecution
))

function DoomsdayClockExecution.new(): DoomsdayClockExecution
	return setmetatable({ active = true, mg = nil, rotState = {} }, DoomsdayClockExecution)
end

function DoomsdayClockExecution.init(self: DoomsdayClockExecution, mg: any, _ticks: number)
	self.mg = mg
end

function DoomsdayClockExecution.tick(self: DoomsdayClockExecution, ticks: number)
	if ticks % 10 ~= 0 then
		return -- once per second
	end
	local mg = self.mg
	local cfg = mg:config():doomsdayClockConfig()
	if not cfg.enabled then
		return
	end
	-- Warships bleed on their own gentler start, higher ceiling and a steep
	-- convex ramp.
	local warshipCfg = table.clone(cfg) :: any
	warshipCfg.drainStartPercent = cfg.warshipDrainStartPercent
	warshipCfg.drainMaxPercent = cfg.warshipDrainMaxPercent

	local elapsed = mg:elapsedGameSeconds()
	-- Humans and nations; tribes are exempt. players() holds the living.
	local contenders = {}
	for _, p in mg:players() do
		if p:type() ~= PlayerType.Bot then
			table.insert(contenders, p)
		end
	end
	local ffa = mg:config():gameConfig().gameMode == GameTypes.GameMode.FFA
	local sides = self:_sides(contenders, ffa)

	if mg:getWinner() ~= nil or #sides < 2 then
		for _, p in contenders do
			p:clearDoomsdayClock()
		end
		self.active = false
		return
	end

	local land = mg:numLandTiles() - mg:numTilesWithFallout()
	local required = DoomsdayClock.requiredTiles({ speed = cfg.speed, teamGame = not ffa }, land, elapsed)

	-- The leading side is never doomed (first of the largest).
	local sideTiles = {}
	for i, members in sides do
		local sum = 0
		for _, m in members do
			sum += m:numTilesOwned()
		end
		sideTiles[i] = sum
	end
	local leader = 1
	for i = 2, #sideTiles do
		if sideTiles[i] > sideTiles[leader] then
			leader = i
		end
	end

	for i, members in sides do
		if i ~= leader and sideTiles[i] < required then
			for _, m in members do
				m:enterDoomsdayClock()
				local secondsUnder = math.floor(m:doomsdayClockTicks() / 10)
				if secondsUnder >= cfg.warnSeconds then
					local secondsPastWarn = secondsUnder - cfg.warnSeconds
					-- Crippled, not wiped: only what sits above the floor.
					local maxTroops = mg:config():maxTroops(m)
					local troopFloor = DoomsdayClock.troopFloor(maxTroops, secondsPastWarn, cfg)
					local chunk = DoomsdayClock.drain(maxTroops, secondsPastWarn, cfg)
					m:removeTroops(math.min(chunk, math.max(0, m:troops() - troopFloor)))
					if cfg.rotDeathSeconds > 0 and secondsPastWarn >= cfg.floorDecaySeconds and m:troops() <= troopFloor then
						self:_rot(mg, m, secondsUnder, cfg)
					end
					-- The navy bleeds toward the same floor, never sunk.
					for _, ws in m:units(UnitType.Warship) do
						local shipFloor = math.floor((ws:maxHealth() * cfg.drainFloorPercent) / 100)
						local removable = math.max(0, ws:health() - shipFloor)
						if removable > 0 then
							local dmg = DoomsdayClock.drain(ws:maxHealth(), secondsPastWarn, warshipCfg, cfg.warshipDrainCurveExponent)
							ws:modifyHealth(-math.min(dmg, removable))
						end
					end
				end
			end
		else
			for _, m in members do
				m:clearDoomsdayClock()
				self.rotState[m:smallID()] = nil -- recovered: rot starts over
			end
		end
	end
end

-- Take territory so the player holds none rotDeathSeconds after the skull.
function DoomsdayClockExecution._rot(self: DoomsdayClockExecution, mg: any, player: any, secondsUnder: number, cfg: any)
	local owned = player:numTilesOwned()
	if owned <= 0 then
		return
	end
	local id = player:smallID()
	local state = self.rotState[id] or { since = mg:ticks(), held = owned, front = newFront() }
	local evenQuota = DoomsdayClock.rotQuota(owned, secondsUnder, cfg)
	-- A grainy opening sized off the territory held when rot began.
	local grainy = mg:ticks() - state.since < cfg.rotGrainSeconds * 10
	local specks = if grainy then math.max(1, math.ceil((state.held * cfg.rotSpecklePercent) / 100 / cfg.rotGrainSeconds)) else 0
	local budget = math.min(owned, math.max(evenQuota, specks))

	local tiles = player:tiles()
	local front = newFront()
	frontEach(state.front, function(tile: number, rotted: number)
		if tiles:has(tile) then
			frontSet(front, tile, rotted)
		end
	end)

	budget -= self:_speckle(mg, player, math.min(specks, budget), front)
	budget -= self:_spread(mg, player, budget, front)
	if budget > 0 then
		self:_speckle(mg, player, budget, front) -- the front ran out
	end
	self.rotState[id] = { since = state.since, held = state.held, front = front }
end

-- Open `count` holes, the interior first, lowest speckle noise first.
function DoomsdayClockExecution._speckle(self: DoomsdayClockExecution, mg: any, player: any, count: number, front: Front): number
	if count <= 0 then
		return 0
	end
	local salt = player:smallID()
	local border = player:borderTiles()
	local interior, edge = lowestN(count), lowestN(count)
	player:tiles():forEach(function(tile: number)
		local key = DoomsdayClock.rotSpeckleNoise(mg:x(tile), mg:y(tile), salt)
		if border:has(tile) then
			edge.offer(tile, key)
		else
			interior.offer(tile, key)
		end
	end)
	local picked = interior.take()
	if interior.size() < count then
		picked = table.clone(picked)
		for _, t in edge.take() do
			table.insert(picked, t)
		end
	end
	local opened = 0
	for _, tile in picked do
		if opened == count then
			break
		end
		if self:_consume(mg, player, tile, front) then
			opened += 1
		end
	end
	return opened
end

-- Grow the holes by up to `count` tiles, tips (fewest rotted neighbours) first.
function DoomsdayClockExecution._spread(self: DoomsdayClockExecution, mg: any, player: any, count: number, front: Front): number
	if count <= 0 or front.size == 0 then
		return 0
	end
	local salt = player:smallID()
	local pick = lowestN(count)
	frontEach(front, function(tile: number, rotted: number)
		pick.offer(tile, rotted * ROT_NOISE_SCALE + DoomsdayClock.rotFrontNoise(tile, salt))
	end)
	local taken = 0
	for _, tile in pick.take() do
		if taken == count then
			break
		end
		if self:_consume(mg, player, tile, front) then
			taken += 1
		end
	end
	return taken
end

-- Rot one tile to fallout and queue its owned neighbours on the front.
function DoomsdayClockExecution._consume(_self: DoomsdayClockExecution, mg: any, player: any, tile: number, front: Front): boolean
	local tiles = player:tiles()
	if not tiles:has(tile) then
		return false
	end
	player:relinquish(tile)
	mg:setFallout(tile, true)
	player:markRotted()
	frontDelete(front, tile)
	for _, neighbour in mg:neighbors(tile) do
		if tiles:has(neighbour) then
			frontSet(front, neighbour, (front.count[neighbour] or 0) + 1)
		end
	end
	return true
end

-- Sides: singletons in FFA, by team otherwise (first-seen team order).
function DoomsdayClockExecution._sides(_self: DoomsdayClockExecution, contenders: { any }, ffa: boolean): { { any } }
	local sides = {}
	if ffa then
		for _, p in contenders do
			table.insert(sides, { p })
		end
		return sides
	end
	local byTeam = {}
	for _, p in contenders do
		local team = p:team()
		if team ~= nil then
			if byTeam[team] == nil then
				byTeam[team] = {}
				table.insert(sides, byTeam[team])
			end
			table.insert(byTeam[team], p)
		end
	end
	return sides
end

function DoomsdayClockExecution.isActive(self: DoomsdayClockExecution): boolean
	return self.active
end

function DoomsdayClockExecution.activeDuringSpawnPhase(_self: DoomsdayClockExecution): boolean
	return false
end

return DoomsdayClockExecution
