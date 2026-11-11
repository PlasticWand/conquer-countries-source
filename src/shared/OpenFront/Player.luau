--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/PlayerImpl.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- One nation, tribe or human. Troops and gold are integer-valued numbers
-- (BigInt in OpenFront), floored on every write exactly like its toInt().
-- Territory, troops, gold, units and building rules, relations, alliances,
-- embargoes, targets, emoji, quick chat, donations, traitor state and attacks.

local ArsenalUnits = require(script.Parent.ArsenalUnits)
local Attack = require(script.Parent.Attack)
local GameMap = require(script.Parent.GameMap)
local GameTypes = require(script.Parent.GameTypes)
local PseudoRandom = require(script.Parent.PseudoRandom)
local TileSet = require(script.Parent.TileSet)
local Unit = require(script.Parent.Unit)
local Util = require(script.Parent.Util)

local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

local DECAY_CUE_GRACE_TICKS = 30
local toInt = Util.toInt

export type PlayerInfo = {
	name: string,
	playerType: string,
	clientID: string?, -- nil for tribes
	id: string,
	isLobbyCreator: boolean?,
	displayName: string?,
	nationFlag: string?,
	friends: { string }?, -- clientIDs (TeamAssignment's friend preference)
	-- Conquest's store: a human's equipped flag and territory skin ids, and
	-- the Arsenal weapons they unlocked ({ megaNuke = true, ... }).
	flag: string?,
	skin: string?,
	weapons: { [string]: boolean }?,
}

-- GameTypes.ts Relation
local Relation = table.freeze({ Hostile = 0, Distrustful = 1, Neutral = 2, Friendly = 3 })

local Player = {}
Player.__index = Player
Player.Relation = Relation

export type Player = typeof(setmetatable(
	{} :: {
		mg: any,
		_smallID: number,
		playerInfo: PlayerInfo,
		_team: any,
		_troops: number,
		_gold: number,
		_goldEarned: number,
		_tradeGold: number,
		_trainGold: number,
		_piracyGold: number,
		_pseudo_random: PseudoRandom.PseudoRandom,
		_tiles: TileSet.TileSet,
		_borderTiles: TileSet.TileSet,
		_lastTileChange: number,
		_tileChangeVersion: number,
		-- Conquest: bumps only when a shore land tile enters or leaves this
		-- player's border set (shoreVersion).
		_shoreVersion: number,
		_units: { Unit.Unit },
		-- Bumped whenever this player's unit list or a unit's level changes
		-- (PlayerImpl.ts _myUnitsVersion); keys the unitCount memo.
		_myUnitsVersion: number,
		_myUnitCountMemo: { [string]: { version: number, count: number } },
		_numUnitsConstructed: { [string]: number },
		_incomingAttacks: { Attack.Attack },
		_outgoingAttacks: { Attack.Attack },
		_alliances: { any },
		relations: { [any]: number },
		relationOrder: { any },
		embargoes: { [string]: { createdAt: number, isTemporary: boolean, target: any } },
		embargoOrder: { string },
		pastOutgoingAllianceRequests: { any },
		targets_: { { tick: number, target: any } },
		outgoingEmojis_: { any },
		outgoingQuickChats_: { [number]: number },
		sentDonations: { { recipient: any, tick: number } },
		lastEmbargoAllTick: number,
		lastDeleteUnitTick: number,
		markedTraitorTick: number,
		markedDoomsdayClockTick: number,
		rottedAtTick: number,
		_betrayalCount: number,
		_spawnTile: number?,
		_isDisconnected: boolean,
	},
	Player
))

-- PlayerImpl constructor
function Player.new(mg: any, smallID: number, playerInfo: PlayerInfo, startTroops: number, team: any): Player
	return setmetatable({
		mg = mg,
		_smallID = smallID,
		playerInfo = playerInfo,
		_team = team,
		_troops = toInt(startTroops),
		_gold = mg:config():startingGold(playerInfo),
		_goldEarned = 0,
		_tradeGold = 0,
		_trainGold = 0,
		_piracyGold = 0,
		_pseudo_random = PseudoRandom.new(Util.simpleHash(playerInfo.id)),
		_tiles = TileSet.new(),
		_borderTiles = TileSet.new(),
		_lastTileChange = 0,
		_tileChangeVersion = 0,
		_shoreVersion = 0,
		_units = {},
		_myUnitsVersion = 0,
		_myUnitCountMemo = {},
		_numUnitsConstructed = {},
		_incomingAttacks = {},
		_outgoingAttacks = {},
		_alliances = {},
		relations = {},
		relationOrder = {},
		embargoes = {},
		embargoOrder = {},
		pastOutgoingAllianceRequests = {},
		targets_ = {},
		outgoingEmojis_ = {},
		outgoingQuickChats_ = {},
		sentDonations = {},
		lastEmbargoAllTick = -1,
		lastDeleteUnitTick = -1,
		markedTraitorTick = -1,
		markedDoomsdayClockTick = -1,
		rottedAtTick = -1,
		_betrayalCount = 0,
		_spawnTile = nil,
		_isDisconnected = false,
	}, Player)
end

function Player.isPlayer(_self: Player): boolean
	return true
end

function Player.smallID(self: Player): number
	return self._smallID
end

function Player.id(self: Player): string
	return self.playerInfo.id
end

function Player.type(self: Player): string
	return self.playerInfo.playerType
end

function Player.info(self: Player): PlayerInfo
	return self.playerInfo
end

function Player.name(self: Player): string
	return self.playerInfo.name
end

function Player.displayName(self: Player): string
	return self.playerInfo.displayName or self.playerInfo.name
end

function Player.clientID(self: Player): string?
	return self.playerInfo.clientID
end

function Player.isLobbyCreator(self: Player): boolean
	return self.playerInfo.isLobbyCreator == true
end

function Player.team(self: Player): any
	return self._team
end

-- Territory ----------------------------------------------------------------------

function Player.numTilesOwned(self: Player): number
	return self._tiles:size()
end

function Player.tiles(self: Player): TileSet.TileSet
	return self._tiles
end

function Player.borderTiles(self: Player): TileSet.TileSet
	return self._borderTiles
end

function Player.conquer(self: Player, tile: number)
	self.mg:conquer(self, tile)
end

function Player.relinquish(self: Player, tile: number)
	if self.mg:owner(tile) ~= self then
		error("Cannot relinquish tile not owned by this player")
	end
	self.mg:relinquish(tile)
end

-- PlayerImpl.ts sharesBorderWith: some border tile touches `other`'s land
-- (smallID 0 matches water and unowned land too, as in OpenFront).
function Player.sharesBorderWith(self: Player, other: any): boolean
	local map = self.mg:map()
	local otherID = other:smallID()
	local nbuf = { 0, 0, 0, 0 }
	for _, border in self._borderTiles:values() do
		local n = map:neighbors4(border, nbuf)
		for i = 1, n do
			if map:ownerID(nbuf[i]) == otherID then
				return true
			end
		end
	end
	return false
end

local SHORE_DX = { 0, 0, -1, 1 }
local SHORE_DY = { -1, 1, 0, 0 }

local IS_LAND = GameMap.IS_LAND
local MAGNITUDE_MASK = GameMap.MAGNITUDE_MASK
local IMPASSABLE_MAGNITUDE = GameMap.IMPASSABLE_MAGNITUDE
local PLAYER_ID_MASK = GameMap.PLAYER_ID_MASK
local FALLOUT = GameMap.FALLOUT

-- nearby's test for a neighbour, over the map buffers: the owner of passable
-- land that isn't ownerless fallout, else -1.
local function landOwner(terrain: buffer, state: buffer, t: number): number
	local bits = buffer.readu8(terrain, t)
	if bit32.band(bits, IS_LAND) == 0 or bit32.band(bits, MAGNITUDE_MASK) == IMPASSABLE_MAGNITUDE then
		return -1
	end
	local s = buffer.readu16(state, t * 2)
	local owner = bit32.band(s, PLAYER_ID_MASK)
	if owner == 0 and bit32.band(s, FALLOUT) ~= 0 then
		return -1
	end
	return owner
end

-- PlayerImpl.ts nearby: owners of land next to our border (plus across
-- rivers up to 4 tiles wide), in first-seen order. Memoised on territory
-- and water versions, like the original.
function Player.nearby(self: Player): { any }
	local mg = self.mg
	local map = mg:map()
	local memo = (self :: any)._nearbyMemo
	if memo ~= nil and memo.version == mg:territoryVersion() and memo.waterVersion == map:waterVersion() then
		return table.clone(memo.result)
	end
	-- Seen by smallID, which maps one to one onto players.
	local seen: { [number]: true } = {}
	local result = {}
	local me = self._smallID
	local function add(owner: number)
		if not seen[owner] then
			seen[owner] = true
			table.insert(result, mg:playerBySmallID(owner))
		end
	end
	-- The land neighbours in forEachNeighbor's order (north, south, west,
	-- east), read from the buffers: this was a large share of the nations'
	-- tick, since any capture anywhere invalidates the memo.
	local terrain, state, w = map.terrain, map.state, map.width_
	local lastRow = (map.height_ - 1) * w
	local borders = self._borderTiles:values()
	for _, border in borders do
		local x = border % w
		if border >= w then
			local owner = landOwner(terrain, state, border - w)
			if owner ~= -1 and owner ~= me then
				add(owner)
			end
		end
		if border < lastRow then
			local owner = landOwner(terrain, state, border + w)
			if owner ~= -1 and owner ~= me then
				add(owner)
			end
		end
		if x ~= 0 then
			local owner = landOwner(terrain, state, border - 1)
			if owner ~= -1 and owner ~= me then
				add(owner)
			end
		end
		if x ~= w - 1 then
			local owner = landOwner(terrain, state, border + 1)
			if owner ~= -1 and owner ~= me then
				add(owner)
			end
		end
	end
	-- shoreReachableNeighbors: every 10th shore border tile looks 5 tiles out.
	local shoreIdx = 0
	for _, border in borders do
		if map:isShore(border) then
			local visit = shoreIdx % 10 == 0
			shoreIdx += 1
			if visit then
				local bx, by = map:x(border), map:y(border)
				for d = 1, 4 do
					local dx, dy = SHORE_DX[d], SHORE_DY[d]
					local x1, y1 = bx + dx, by + dy
					if map:isValidCoord(x1, y1) and map:isWater(map:ref(x1, y1)) then
						local nx, ny = bx + dx * 5, by + dy * 5
						if map:isValidCoord(nx, ny) then
							local tile = map:ref(nx, ny)
							if
								map:isLand(tile)
								and not map:isImpassable(tile)
								and not (not map:hasOwner(tile) and map:hasFallout(tile))
							then
								local owner = map:ownerID(tile)
								if owner ~= me then
									add(owner)
								end
							end
						end
					end
				end
			end
		end
	end
	;(self :: any)._nearbyMemo = { version = mg:territoryVersion(), waterVersion = map:waterVersion(), result = result }
	return table.clone(result)
end

function Player.isAlive(self: Player): boolean
	return self._tiles:size() > 0
end

function Player.hasSpawned(self: Player): boolean
	return self._spawnTile ~= nil
end

function Player.setSpawnTile(self: Player, tile: number)
	self._spawnTile = tile
end

function Player.spawnTile(self: Player): number?
	return self._spawnTile
end

function Player.lastTileChange(self: Player): number
	return self._lastTileChange
end

function Player.tileChangeVersion(self: Player): number
	return self._tileChangeVersion
end

-- Conquest (Bruno, 2026-11-08: server spikes mid-late game): changes exactly
-- when the player's shore tiles in border order change, i.e. when a shore
-- land tile enters or leaves its border set (Game.updateBorderStatus,
-- conquer, relinquish). A shore tile is always a border tile (its water
-- neighbour is unowned), so inland conquests don't touch it. Caches that
-- read only the shore tiles key on this instead of tileChangeVersion, which
-- changes every tick in a war; they give the same answers, just less often
-- recomputed.
function Player.shoreVersion(self: Player): number
	return self._shoreVersion
end

-- Troops and gold -------------------------------------------------------------

function Player.troops(self: Player): number
	return self._troops
end

function Player.setTroops(self: Player, troops: number)
	self._troops = toInt(troops)
end

function Player.addTroops(self: Player, troops: number)
	if troops < 0 then
		self:removeTroops(-1 * troops)
		return
	end
	self._troops += toInt(troops)
end

-- Returns how many were actually removed.
function Player.removeTroops(self: Player, troops: number): number
	if troops <= 0 then
		return 0
	end
	local toRemove = math.min(self._troops, toInt(troops))
	self._troops -= toRemove
	return toRemove
end

function Player.gold(self: Player): number
	return self._gold
end

function Player.goldEarned(self: Player): number
	return self._goldEarned
end

-- A tile marks a visible bonus (trade, trains, piracy): the client shows it.
function Player.addGold(self: Player, toAdd: number, tile: number?)
	self._gold += toAdd
	self._goldEarned += toAdd
	if tile then
		self.mg:addUpdate({ type = "BonusEvent", player = self:id(), tile = tile, gold = toAdd, troops = 0 })
	end
end

function Player.tradeGold(self: Player): number
	return self._tradeGold
end
function Player.addTradeGold(self: Player, toAdd: number)
	self._tradeGold += toAdd
end
function Player.trainGold(self: Player): number
	return self._trainGold
end
function Player.addTrainGold(self: Player, toAdd: number)
	self._trainGold += toAdd
end
function Player.piracyGold(self: Player): number
	return self._piracyGold
end
function Player.addPiracyGold(self: Player, toAdd: number)
	self._piracyGold += toAdd
end

function Player.removeGold(self: Player, toRemove: number): number
	if toRemove <= 0 then
		return 0
	end
	local actual = math.min(self._gold, toRemove)
	self._gold -= actual
	return actual
end

-- Units ------------------------------------------------------------------------

-- units() with no type returns every unit; with a type or a list of types,
-- only those, in the player's unit order.
function Player.units(self: Player, unitType: (string | { string })?): { Unit.Unit }
	if unitType == nil then
		return self._units
	end
	local out = {}
	if type(unitType) == "string" then
		for _, u in self._units do
			if u:type() == unitType then
				table.insert(out, u)
			end
		end
	else
		local wanted = {}
		for _, t in unitType :: { string } do
			wanted[t] = true
		end
		for _, u in self._units do
			if wanted[u:type()] then
				table.insert(out, u)
			end
		end
	end
	return out
end

function Player.unitsConstructed(self: Player, unitType: string): number
	return self._numUnitsConstructed[unitType] or 0
end

-- Sum of levels, counting units under construction as 1.
function Player.unitsOwned(self: Player, unitType: string): number
	local total = 0
	for _, u in self._units do
		if u:type() == unitType then
			total += if u:isUnderConstruction() then 1 else u:level()
		end
	end
	return total
end

-- PlayerImpl.ts unitCount, with its memo (myUnitCountMemo): the walk runs
-- again only after this player's units changed.
function Player.unitCount(self: Player, unitType: string): number
	local memo = self._myUnitCountMemo[unitType]
	if memo ~= nil and memo.version == self._myUnitsVersion then
		return memo.count
	end
	local total = 0
	for _, u in self._units do
		if u:type() == unitType then
			total += u:level()
		end
	end
	self._myUnitCountMemo[unitType] = { version = self._myUnitsVersion, count = total }
	return total
end

-- Doomsday clock (a game modifier) -------------------------------------------------

function Player.inDoomsdayClock(self: Player): boolean
	return self:isAlive() and self.markedDoomsdayClockTick >= 0
end

-- Ticks spent continuously below the doomsday-clock bar.
function Player.doomsdayClockTicks(self: Player): number
	return if self:inDoomsdayClock() then self.mg:ticks() - self.markedDoomsdayClockTick else 0
end

function Player.enterDoomsdayClock(self: Player)
	if self.markedDoomsdayClockTick < 0 then
		self.markedDoomsdayClockTick = self.mg:ticks()
	end
end

function Player.clearDoomsdayClock(self: Player)
	self.markedDoomsdayClockTick = -1
	self.rottedAtTick = -1
end

function Player.markRotted(self: Player)
	self.rottedAtTick = self.mg:ticks()
end

-- Territory actively rotting (stamped by the execution, so clients don't flicker).
function Player.isDecaying(self: Player): boolean
	if not self:inDoomsdayClock() or self.rottedAtTick < 0 then
		return false
	end
	return self.mg:ticks() - self.rottedAtTick <= DECAY_CUE_GRACE_TICKS
end

-- PlayerImpl.ts canBuildUnitType
-- Conquest's Arsenal: the match has extra weapons on and this player
-- unlocked `key` (PlayerInfo.weapons, from their saved profile).
function Player.hasExtraWeapon(self: Player, key: string): boolean
	local weapons = self.playerInfo.weapons
	return self.mg:config():extraWeapons() and weapons ~= nil and weapons[key] == true
end

function Player._canBuildUnitType(self: Player, unitType: string, knownCost: number?): boolean
	local mg = self.mg
	if mg:config():isUnitDisabled(unitType) then
		return false
	end
	-- Conquest's Arsenal: only once unlocked (ArsenalUnits).
	local weapon = ArsenalUnits.KEY[unitType]
	if weapon ~= nil and not self:hasExtraWeapon(weapon) then
		return false
	end
	local cost = knownCost or mg:unitInfo(unitType).cost(mg, self)
	if self._gold < cost then
		return false
	end
	if unitType ~= UnitType.MIRVWarhead and not self:isAlive() then
		return false
	end
	return true
end

-- PlayerImpl.ts canBuild: the spawn tile for a unit of this type at
-- `targetTile`, or false.
function Player.canBuild(self: Player, unitType: string, targetTile: number, validTiles: { number }?): number | false
	if not self:_canBuildUnitType(unitType) then
		return false
	end
	return self:_canSpawnUnitType(unitType, targetTile, validTiles)
end

function Player._canSpawnUnitType(self: Player, unitType: string, targetTile: number, validTiles: { number }?): number | false
	if unitType == UnitType.MIRV then
		if not self.mg:hasOwner(targetTile) then
			return false
		end
		return self:nukeSpawn(targetTile, unitType)
	elseif unitType == UnitType.AtomBomb or unitType == UnitType.HydrogenBomb or unitType == UnitType.MegaNuke or unitType == UnitType.Scattershot then
		return self:nukeSpawn(targetTile, unitType)
	elseif unitType == UnitType.MIRVWarhead or unitType == UnitType.Shell or unitType == UnitType.SAMMissile or unitType == UnitType.ArtilleryShell then
		return targetTile
	elseif unitType == UnitType.AirStrike or unitType == UnitType.RailgunShot then
		return self:strikeSpawn(targetTile, unitType)
	elseif unitType == UnitType.Paratroopers then
		return self:paraSpawn(targetTile)
	elseif unitType == UnitType.FieldWorks then
		return self:fieldWorksSpawn(targetTile)
	elseif unitType == UnitType.Sabotage then
		local target = self:sabotageTarget(targetTile)
		return if target ~= nil then target:tile() else false
	elseif unitType == UnitType.Port or unitType == UnitType.CoastalBattery then
		-- (Our Coastal Battery takes the Port's shore rule; ARSENAL_V2.)
		return self:portSpawn(targetTile, validTiles)
	elseif unitType == UnitType.Warship then
		return self:warshipSpawn(targetTile)
	elseif unitType == UnitType.TransportShip then
		return require(script.Parent.TransportShipUtils).canBuildTransportShip(self.mg, self, targetTile)
	elseif unitType == UnitType.TradeShip then
		return self:tradeShipSpawn(targetTile)
	elseif unitType == UnitType.Train then
		return self:landBasedUnitSpawn(targetTile)
	elseif GameTypes.isStructure[unitType] then
		return self:landBasedStructureSpawn(targetTile, validTiles)
	end
	error(`unknown unit type {unitType}`)
end

-- PlayerImpl.ts nukeSpawn: the closest ready silo, or false.
-- Conquest's Arsenal (RoWorld's launch rules, reference/roworld 2be8efb
-- Core/SimNukes.luau): where an Air Strike or Railgun shot at `tile` leaves
-- from: the nearest (manhattan) finished, loaded launcher of its kind, an
-- Airfield only within its reach of the target. Never at your own or a
-- friend's land, nor while spawn immunity lasts.
function Player.strikeSpawn(self: Player, tile: number, unitType: string): number | false
	local mg = self.mg
	if mg:isSpawnImmunityActive() then
		return false
	end
	local owner = mg:owner(tile)
	if owner:isPlayer() and (owner == self or self:isFriendly(owner)) then
		return false
	end
	local spec = (require(script.Parent.Executions.StrikeExecution) :: any).SPEC[unitType]
	local reach2 = spec.reach * spec.reach
	local tx, ty = mg:x(tile), mg:y(tile)
	local best, bestD = nil, math.huge
	for _, launcher in self:units(spec.launcher) do
		if launcher:isActive() and not launcher:isUnderConstruction() and not launcher:isInCooldown() and not launcher:isDark() then
			if spec.reach == 0 or mg:euclideanDistSquared(launcher:tile(), tile) <= reach2 then
				local d = math.abs(mg:x(launcher:tile()) - tx) + math.abs(mg:y(launcher:tile()) - ty)
				if d < bestD then
					best, bestD = launcher, d
				end
			end
		end
	end
	return if best then best:tile() else false
end

-- Our own Arsenal item (docs/design/ARSENAL_V2.md, Field Works): `tile` if
-- earthworks may go there: our own land within NEAR_FRONT tiles of land a
-- player we may attack owns, at most MAX standing, after the cooldown, never
-- while spawn immunity lasts. Structure spacing doesn't apply.
function Player.fieldWorksSpawn(self: Player, tile: number): number | false
	local mg = self.mg
	if mg:isSpawnImmunityActive() or mg:owner(tile) ~= self then
		return false
	end
	local FieldWorks = require(script.Parent.Executions.FieldWorksExecution) :: any
	if ((self :: any).fieldWorksReadyAt or 0) > mg:ticks() or #self:units(UnitType.FieldWorks) >= FieldWorks.MAX then
		return false
	end
	local r = FieldWorks.NEAR_FRONT
	local cx, cy = mg:x(tile), mg:y(tile)
	for y = math.max(0, cy - r), math.min(mg:height() - 1, cy + r) do
		for x = math.max(0, cx - r), math.min(mg:width() - 1, cx + r) do
			local dx, dy = x - cx, y - cy
			if dx * dx + dy * dy <= r * r then
				local owner = mg:owner(mg:ref(x, y))
				if owner:isPlayer() and owner ~= self and not self:isFriendly(owner) and self:canAttackPlayer(owner) then
					return tile
				end
			end
		end
	end
	return false
end

-- Our own Arsenal item (docs/design/ARSENAL_V2.md, Sabotage): the building a
-- sabotage aimed at `tile` would hit: the nearest finished structure within
-- 4 tiles owned by a player we may attack, not already dark, within 60
-- tiles of our land (ties to the lower id). Nil while spawn immunity lasts,
-- one is under way, or the cooldown runs.
function Player.sabotageTarget(self: Player, tile: number): any?
	local mg = self.mg
	if mg:isSpawnImmunityActive() then
		return nil
	end
	if ((self :: any).sabotageReadyAt or 0) > mg:ticks() or #self:units(UnitType.Sabotage) > 0 then
		return nil
	end
	local best: any, bestD = nil, math.huge
	for _, entry in mg:nearbyUnits(tile, 4, GameTypes.Structures) do
		local unit = entry.unit
		local owner = unit:owner()
		if
			unit:isActive()
			and not unit:isDark()
			and owner:isPlayer()
			and owner ~= self
			and not self:isFriendly(owner)
			and self:canAttackPlayer(owner)
			and (entry.distSquared < bestD or (entry.distSquared == bestD and unit:id() < best:id()))
		then
			best, bestD = unit, entry.distSquared
		end
	end
	if best == nil then
		return nil
	end
	local reach = (require(script.Parent.Executions.SabotageExecution) :: any).REACH
	local reach2 = reach * reach
	local at = best:tile()
	for _, t in self:borderTiles():values() do
		if mg:euclideanDistSquared(t, at) <= reach2 then
			return best
		end
	end
	return nil
end

-- Our own Arsenal item (docs/design/ARSENAL_V2.md, Paratroopers): where a
-- drop on `tile` takes off from: the nearest (Manhattan, ties to the lower
-- tile) finished City or Airfield of ours within the plane's reach of the
-- target. Only onto land we may attack or nobody owns, one plane at a time,
-- after the cooldown, never while spawn immunity lasts.
function Player.paraSpawn(self: Player, tile: number): number | false
	local mg = self.mg
	if mg:isSpawnImmunityActive() or not mg:isLand(tile) then
		return false
	end
	local owner = mg:owner(tile)
	if owner:isPlayer() and (owner == self or self:isFriendly(owner) or not self:canAttackPlayer(owner)) then
		return false
	end
	if ((self :: any).paraReadyAt or 0) > mg:ticks() or #self:units(UnitType.Paratroopers) > 0 then
		return false
	end
	local reach = (require(script.Parent.Executions.ParatroopersExecution) :: any).REACH
	local reach2 = reach * reach
	local tx, ty = mg:x(tile), mg:y(tile)
	local best, bestD = nil, math.huge
	for _, t in { UnitType.City, UnitType.Airfield } do
		for _, base in self:units(t) do
			if base:isActive() and not base:isUnderConstruction() and mg:euclideanDistSquared(base:tile(), tile) <= reach2 then
				local at = base:tile()
				local d = math.abs(mg:x(at) - tx) + math.abs(mg:y(at) - ty)
				if d < bestD or (d == bestD and at < (best :: number)) then
					best, bestD = at, d
				end
			end
		end
	end
	return if best ~= nil then best else false
end

function Player.nukeSpawn(self: Player, tile: number, nukeType: string): number | false
	local mg = self.mg
	if mg:isSpawnImmunityActive() then
		return false
	end
	if mg:isImpassable(tile) then
		return false
	end
	local owner = mg:owner(tile)
	local config = mg:config()
	local gameOver = mg:getWinner() ~= nil and config:gameConfig().gameType ~= GameTypes.GameType.Singleplayer
	if owner:isPlayer() then
		if self:isOnSameTeam(owner) and not gameOver then
			return false
		end
	end
	if config:gameConfig().gameMode == GameTypes.GameMode.Team and nukeType ~= UnitType.MIRV and not gameOver then
		local magnitude = config:nukeMagnitudes(nukeType)
		local wouldHitTeammate = mg:anyUnitNearby(tile, magnitude.outer, GameTypes.Structures, function(unit)
			return unit:owner():isPlayer() and self:isOnSameTeam(unit:owner())
		end)
		if wouldHitTeammate then
			return false
		end
	end
	local readySilos = {}
	for _, silo in self:units(UnitType.MissileSilo) do
		-- (Conquest's Sabotage: not while dark.)
		if silo:isActive() and not silo:isInCooldown() and not silo:isUnderConstruction() and not silo:isDark() then
			table.insert(readySilos, silo)
		end
	end
	readySilos = Util.stableSort(readySilos, function(a, b)
		return mg:manhattanDist(a:tile(), tile) < mg:manhattanDist(b:tile(), tile)
	end)
	return if readySilos[1] then readySilos[1]:tile() else false
end

-- PlayerImpl.ts portSpawn: the closest own shore tile (Manhattan, within
-- radiusPortSpawn) that is a valid structure tile.
function Player.portSpawn(self: Player, tile: number, validTiles: { number }?): number | false
	local mg = self.mg
	local GameMap = require(script.Parent.GameMap)
	local spawns = {}
	for _, t in mg:bfs(tile, GameMap.manhattanDistFN(tile, mg:config():radiusPortSpawn())) do
		if mg:owner(t) == self and mg:isShore(t) then
			table.insert(spawns, t)
		end
	end
	spawns = Util.stableSort(spawns, function(a, b)
		return mg:manhattanDist(a, tile) < mg:manhattanDist(b, tile)
	end)
	local validSet = {}
	for _, t in validTiles or self:_validStructureSpawnTiles(tile) do
		validSet[t] = true
	end
	for _, t in spawns do
		if validSet[t] then
			return t
		end
	end
	return false
end

-- PlayerImpl.ts warshipSpawn: the closest finished port on the same water body.
function Player.warshipSpawn(self: Player, tile: number): number | false
	local mg = self.mg
	if not mg:isWater(tile) then
		return false
	end
	local tileComponent = mg:getWaterComponent(tile)
	local bestPort = Util.findClosestBy(self:units(UnitType.Port), function(port)
		return mg:manhattanDist(port:tile(), tile)
	end, function(port)
		return port:isActive()
			and not port:isUnderConstruction()
			and tileComponent ~= nil
			and mg:hasWaterComponent(port:tile(), tileComponent)
	end)
	return if bestPort then bestPort:tile() else false
end

function Player.landBasedUnitSpawn(self: Player, tile: number): number | false
	return if self.mg:isLand(tile) and not self.mg:isImpassable(tile) then tile else false
end

function Player.landBasedStructureSpawn(self: Player, tile: number, validTiles: { number }?): number | false
	local tiles = validTiles or self:_validStructureSpawnTiles(tile)
	if #tiles == 0 then
		return false
	end
	return tiles[1]
end

-- PlayerImpl.ts validStructureSpawnTiles: own tiles within radius 15 of
-- `tile` that are at least structureMinDist from every structure, closest
-- first. The flood uses GameMap.bfs order (stack, N/S/W/E) so ties keep it.
function Player._validStructureSpawnTiles(self: Player, tile: number): { number }
	local mg = self.mg
	if mg:owner(tile) ~= self then
		return {}
	end
	local searchRadius = 15
	local searchRadiusSquared = searchRadius * searchRadius
	local nearbyUnits = mg:nearbyUnits(tile, searchRadius * 2, GameTypes.Structures, nil, true)
	local map = mg:map()
	local w = map:width()
	local cx, cy = tile % w, tile // w
	local smallID = self._smallID
	local function inside(t: number): boolean
		local dx, dy = t % w - cx, t // w - cy
		return dx * dx + dy * dy < searchRadiusSquared and map:ownerID(t) == smallID
	end
	local scratch = mg:traversalScratch()
	local gen = mg:bumpTraversalGeneration()
	local visited = scratch.visited
	local stack = {}
	local nearbyTiles = {}
	if inside(tile) then
		buffer.writeu32(visited, tile * 4, gen)
		table.insert(nearbyTiles, tile)
		table.insert(stack, tile)
	end
	local function visit(n: number)
		if buffer.readu32(visited, n * 4) ~= gen and inside(n) then
			buffer.writeu32(visited, n * 4, gen)
			table.insert(nearbyTiles, n)
			table.insert(stack, n)
		end
	end
	while #stack > 0 do
		map:forEachNeighbor(table.remove(stack) :: number, visit)
	end
	local minDist = mg:config():structureMinDist()
	local minDistSquared = minDist * minDist
	local valid = {}
	for _, t in nearbyTiles do
		local blocked = false
		for _, entry in nearbyUnits do
			if mg:euclideanDistSquared(entry.unit:tile(), t) < minDistSquared then
				blocked = true
				break
			end
		end
		if not blocked then
			table.insert(valid, t)
		end
	end
	return Util.stableSort(valid, function(a, b)
		return mg:euclideanDistSquared(a, tile) < mg:euclideanDistSquared(b, tile)
	end)
end

function Player.validStructureSpawnTiles(self: Player, tile: number): { number }
	return self:_validStructureSpawnTiles(tile)
end

function Player.tradeShipSpawn(self: Player, targetTile: number): number | false
	for _, u in self:units(UnitType.Port) do
		if u:tile() == targetTile then
			return targetTile
		end
	end
	return false
end

-- PlayerImpl.ts findUnitToUpgrade: the closest own unit of `unitType`
-- within structureMinDist that can be upgraded now, or false.
function Player.findUnitToUpgrade(self: Player, unitType: string, targetTile: number): Unit.Unit | false
	local mg = self.mg
	local closest = Util.findClosestBy(mg:nearbyUnits(targetTile, mg:config():structureMinDist(), unitType, nil, true), function(entry: any)
		return entry.distSquared
	end)
	if closest == nil or not self:canUpgradeUnit(closest.unit) then
		return false
	end
	return closest.unit
end

export type BuildableUnit = {
	type: string,
	canBuild: number | false,
	canUpgrade: number | false,
	cost: number,
	upgradeCosts: { number }?,
	overlappingRailroads: { number },
	ghostRailPaths: { { number } },
}

-- PlayerImpl.ts buildableUnits, for one tile: for each type its cost, the
-- unit a click there would upgrade (id), the tile a new one would be built
-- on (or false), the cumulative bulk-upgrade totals and the rail previews.
function Player.buildableUnits(self: Player, tile: number?, units: { string }): { BuildableUnit }
	local mg = self.mg
	local config = mg:config()
	local inSpawnPhase = mg:inSpawnPhase()
	local needsTiles = false
	for _, u in units do
		needsTiles = needsTiles or GameTypes.isStructure[u] == true
	end
	local validTiles = if tile ~= nil and needsTiles then self:_validStructureSpawnTiles(tile) else {}
	local result = {}
	for _, u in units do
		local cost = config:unitInfo(u).cost(mg, self)
		local canUpgrade: number | false, canBuild: number | false = false, false
		if tile ~= nil and self:_canBuildUnitType(u, cost) and not inSpawnPhase then
			if config:unitInfo(u).upgradable then
				local closest = Util.findClosestBy(mg:nearbyUnits(tile, config:structureMinDist(), u, nil, true), function(entry: any)
					return entry.distSquared
				end)
				local existing = if closest then closest.unit else nil
				if existing and not existing:isUnderConstruction() and not existing:isMarkedForDeletion() and existing:owner() == self then
					canUpgrade = existing:id()
				end
			end
			canBuild = self:_canSpawnUnitType(u, tile, validTiles)
		end
		local buildNew = canBuild ~= false and canUpgrade == false
		-- Each upgrade raises the level and the constructed count, so step n
		-- costs what it would with n more units: cost(mg, self, n).
		local upgradeCosts: { number }? = nil
		if canUpgrade ~= false then
			local totals = table.create(GameTypes.MAX_UPGRADE_AMOUNT)
			local total = 0
			for n = 0, GameTypes.MAX_UPGRADE_AMOUNT - 1 do
				total += config:unitInfo(u).cost(mg, self, n)
				totals[n + 1] = total
			end
			upgradeCosts = totals
		end
		local rail = mg:railNetwork()
		table.insert(result, {
			type = u,
			canBuild = canBuild,
			canUpgrade = canUpgrade,
			cost = cost,
			upgradeCosts = upgradeCosts,
			overlappingRailroads = if buildNew then rail:overlappingRailroads(u, canBuild :: number) else {},
			ghostRailPaths = if buildNew then rail:computeGhostRailPaths(u, canBuild :: number) else {},
		})
	end
	return result
end

function Player.canUpgradeUnit(self: Player, unit: Unit.Unit): boolean
	if not self.mg:config():unitInfo(unit:type()).upgradable then
		return false
	end
	if not self:_canBuildUnitType(unit:type()) then
		return false
	end
	if unit:isUnderConstruction() or unit:isMarkedForDeletion() or unit:owner() ~= self then
		return false
	end
	return true
end

function Player.upgradeUnit(self: Player, unit: Unit.Unit)
	local cost = self.mg:unitInfo(unit:type()).cost(self.mg, self)
	self:removeGold(cost)
	unit:increaseLevel()
	self._numUnitsConstructed[unit:type()] = (self._numUnitsConstructed[unit:type()] or 0) + 1
end

-- PlayerImpl.ts canTrade
function Player.canTrade(self: Player, other: Player): boolean
	local embargo = other:hasEmbargoAgainst(self) or self:hasEmbargoAgainst(other)
	return not embargo and other:id() ~= self:id()
end

function Player.tradingPartners(self: Player): { Player }
	local out = {}
	for _, other in self.mg:players() do
		if other ~= self and self:canTrade(other) then
			table.insert(out, other)
		end
	end
	return out
end

-- PlayerImpl.ts bestTransportShipSpawn
function Player.bestTransportShipSpawn(self: Player, targetTile: number): number | false
	return require(script.Parent.TransportShipUtils).bestShoreDeploymentSource(self.mg, self, targetTile) or false
end

-- PlayerImpl.ts buildUnit: pays the price and places the unit at once.
function Player.buildUnit(self: Player, unitType: string, spawnTile: number, params: Unit.Params?): Unit.Unit
	local mg = self.mg
	if mg:config():isUnitDisabled(unitType) then
		error(`Attempted to build disabled unit {unitType} at tile {spawnTile} by player {self:name()}`)
	end
	local cost = mg:unitInfo(unitType).cost(mg, self)
	local b = Unit.new(unitType, spawnTile, mg:nextUnitID(), self, params)
	table.insert(self._units, b)
	self._myUnitsVersion += 1
	mg:_unitsChanged()
	self._numUnitsConstructed[unitType] = (self._numUnitsConstructed[unitType] or 0) + 1
	self:removeGold(cost)
	self:removeTroops((params and params.troops) or 0)
	mg:addUnit(b)
	return b
end

function Player.captureUnit(self: Player, unit: Unit.Unit)
	if unit:owner() == self then
		error("Cannot capture unit: already owned")
	end
	unit:setOwner(self)
end

-- Relations and diplomacy ------------------------------------------------------
-- relations and embargoes keep JS Map insertion order (relationOrder,
-- embargoOrder): nation AI iterates them.

local function relationFromValue(value: number): number
	if value < -50 then
		return Relation.Hostile
	elseif value < 0 then
		return Relation.Distrustful
	elseif value < 50 then
		return Relation.Neutral
	end
	return Relation.Friendly
end

function Player.relation(self: Player, other: Player): number
	if other == self then
		error("cannot get relation with self")
	end
	return relationFromValue(self.relations[other] or 0)
end

-- Living players we have a relation with, most hostile first.
function Player.allRelationsSorted(self: Player): { { player: Player, relation: number } }
	local list = {}
	for _, p in self.relationOrder do
		if p:isAlive() then
			table.insert(list, { player = p, value = self.relations[p] })
		end
	end
	list = Util.stableSort(list, function(a, b)
		return a.value < b.value
	end)
	local out = {}
	for _, r in list do
		table.insert(out, { player = r.player, relation = relationFromValue(r.value) })
	end
	return out
end

function Player.updateRelation(self: Player, other: Player, delta: number)
	if other == self then
		error("cannot update relation with self")
	end
	if self.relations[other] == nil then
		table.insert(self.relationOrder, other)
	end
	self.relations[other] = Util.within((self.relations[other] or 0) + delta, -100, 100)
end

function Player.decayRelations(self: Player)
	for _, p in self.relationOrder do
		local r = self.relations[p]
		local sign = -1 * math.sign(r)
		local delta = 0.05
		r += sign * delta
		if math.abs(r) < delta * 2 then
			r = 0
		end
		self.relations[p] = r
	end
end

-- Embargoes ---------------------------------------------------------------------

function Player.addEmbargo(self: Player, other: Player, isTemporary: boolean)
	local embargo = self.embargoes[other:id()]
	if embargo ~= nil and not embargo.isTemporary then
		return
	end
	self.mg:addUpdate({ type = "EmbargoEvent", event = "start", playerID = self:smallID(), embargoedID = other:smallID() })
	if embargo == nil then
		table.insert(self.embargoOrder, other:id())
	end
	self.embargoes[other:id()] = { createdAt = self.mg:ticks(), isTemporary = isTemporary, target = other }
end

function Player.getEmbargoes(self: Player): { { createdAt: number, isTemporary: boolean, target: any } }
	local out = {}
	for _, id in self.embargoOrder do
		table.insert(out, self.embargoes[id])
	end
	return out
end

function Player.stopEmbargo(self: Player, other: Player)
	local id = other:id()
	if self.embargoes[id] ~= nil then
		self.embargoes[id] = nil
		table.remove(self.embargoOrder, table.find(self.embargoOrder, id) :: number)
	end
	self.mg:addUpdate({ type = "EmbargoEvent", event = "stop", playerID = self:smallID(), embargoedID = other:smallID() })
end

function Player.endTemporaryEmbargo(self: Player, other: Player)
	local embargo = self.embargoes[other:id()]
	if embargo ~= nil and not embargo.isTemporary then
		return
	end
	self:stopEmbargo(other)
end

function Player.hasEmbargoAgainst(self: Player, other: Player): boolean
	return self.embargoes[other:id()] ~= nil
end

function Player.hasManualEmbargoAgainst(self: Player, other: Player): boolean
	local e = self.embargoes[other:id()]
	return e ~= nil and e.isTemporary == false
end

function Player.canEmbargoAll(self: Player): boolean
	if self.mg:ticks() - self.lastEmbargoAllTick < self.mg:config():embargoAllCooldown() then
		return false
	end
	for _, p in self.mg:players() do
		if p:id() ~= self:id() and p:type() ~= PlayerType.Bot and not self:isOnSameTeam(p) and not self:isAlliedWith(p) then
			return true
		end
	end
	return false
end

function Player.recordEmbargoAll(self: Player)
	self.lastEmbargoAllTick = self.mg:ticks()
end

-- Alliances ---------------------------------------------------------------------

function Player.incomingAllianceRequests(self: Player): { any }
	local out = {}
	for _, ar in self.mg.allianceRequests do
		if ar:recipient() == self then
			table.insert(out, ar)
		end
	end
	return out
end

function Player.outgoingAllianceRequests(self: Player): { any }
	local out = {}
	for _, ar in self.mg.allianceRequests do
		if ar:requestor() == self then
			table.insert(out, ar)
		end
	end
	return out
end

function Player.alliances(self: Player): { any }
	return self._alliances
end

function Player.allies(self: Player): { Player }
	local out = {}
	for _, a in self._alliances do
		table.insert(out, a:other(self))
	end
	return out
end

-- PlayerImpl.ts allianceInfo: expiry and extension state, for the UI.
function Player.allianceInfo(self: Player, other: Player): { [string]: any }?
	local alliance = self:allianceWith(other)
	if not alliance then
		return nil
	end
	local inWindow = alliance:expiresAt() <= self.mg:ticks() + self.mg:config():allianceExtensionPromptOffset()
	local canExtend = not self:isDisconnected()
		and not other:isDisconnected()
		and self:isAlive()
		and other:isAlive()
		and inWindow
		and not alliance:agreedToExtend(self)
	return {
		expiresAt = alliance:expiresAt(),
		inExtensionWindow = inWindow,
		myPlayerAgreedToExtend = alliance:agreedToExtend(self),
		otherAgreedToExtend = alliance:agreedToExtend(other),
		canExtend = canExtend,
	}
end

function Player.canSendAllianceRequest(self: Player, other: Player): boolean
	local mg = self.mg
	if mg:config():disableAlliances() then
		return false
	end
	if other == self then
		return false
	end
	-- Disconnected players count as unfriendly even when allied: stop first.
	if self:isDisconnected() or other:isDisconnected() then
		return false
	end
	if self:isFriendly(other) or not self:isAlive() then
		return false
	end
	for _, ar in self:outgoingAllianceRequests() do
		if ar:recipient() == other then
			return false
		end
	end
	for _, ar in self:incomingAllianceRequests() do
		if ar:requestor() == other then
			return true
		end
	end
	local latest: number? = nil
	for _, ar in self.pastOutgoingAllianceRequests do
		if ar:recipient() == other and (latest == nil or ar:createdAt() > latest) then
			latest = ar:createdAt()
		end
	end
	if latest == nil then
		return true
	end
	return mg:ticks() - latest >= mg:config():allianceRequestCooldown()
end

function Player.createAllianceRequest(self: Player, recipient: Player): any?
	if self:isAlliedWith(recipient) then
		error("cannot create alliance request, already allies")
	end
	return self.mg:createAllianceRequest(self, recipient)
end

-- Targets, emoji, quick chat ---------------------------------------------------------

function Player.canTarget(self: Player, other: Player): boolean
	if self == other or self:isFriendly(other) then
		return false
	end
	for _, t in self.targets_ do
		if self.mg:ticks() - t.tick < self.mg:config():targetCooldown() then
			return false
		end
	end
	return true
end

function Player.target(self: Player, other: Player)
	table.insert(self.targets_, { tick = self.mg:ticks(), target = other })
	self.mg:target(self, other)
end

function Player.targets(self: Player): { Player }
	local out = {}
	for _, t in self.targets_ do
		if self.mg:ticks() - t.tick < self.mg:config():targetDuration() then
			table.insert(out, t.target)
		end
	end
	return out
end

-- Allies' targets first, then ours, each once.
function Player.transitiveTargets(self: Player): { Player }
	local out, seen = {}, {}
	local function add(p: Player)
		if not seen[p] then
			seen[p] = true
			table.insert(out, p)
		end
	end
	for _, a in self._alliances do
		for _, t in a:other(self):targets() do
			add(t)
		end
	end
	for _, t in self:targets() do
		add(t)
	end
	return out
end

-- recipient is a Player or GameTypes.AllPlayers ("AllPlayers").
function Player.sendEmoji(self: Player, recipient: any, emoji: string)
	if recipient == self then
		error("Cannot send emoji to oneself")
	end
	local msg = {
		message = emoji,
		senderID = self:smallID(),
		recipientID = if recipient == GameTypes.AllPlayers then recipient else recipient:smallID(),
		createdAt = self.mg:ticks(),
	}
	table.insert(self.outgoingEmojis_, msg)
	self.mg:sendEmojiUpdate(msg)
end

function Player.outgoingEmojis(self: Player): { any }
	local out = {}
	for _, e in self.outgoingEmojis_ do
		if self.mg:ticks() - e.createdAt < self.mg:config():emojiMessageDuration() then
			table.insert(out, e)
		end
	end
	return Util.stableSort(out, function(a, b)
		return a.createdAt > b.createdAt
	end)
end

function Player.canSendEmoji(self: Player, recipient: any): boolean
	if recipient == self then
		return false
	end
	local recipientID = if recipient == GameTypes.AllPlayers then recipient else recipient:smallID()
	local window = self.mg:config():emojiMessageWindow()
	local recent = 0
	for _, msg in self.outgoingEmojis_ do
		if msg.recipientID == recipientID and self.mg:ticks() - msg.createdAt < window then
			recent += 1
		end
	end
	-- Nations pace themselves to one per window.
	local limit = if self:type() == PlayerType.Human then self.mg:config():emojiMessageLimit() else 1
	return recent < limit
end

function Player.canSendQuickChat(self: Player, recipient: Player): boolean
	if recipient == self then
		return false
	end
	local last = self.outgoingQuickChats_[recipient:smallID()]
	return last == nil or self.mg:ticks() - last >= self.mg:config():quickChatCooldown()
end

function Player.recordQuickChat(self: Player, recipient: Player)
	self.outgoingQuickChats_[recipient:smallID()] = self.mg:ticks()
end

-- Donations ---------------------------------------------------------------------

function Player._canDonate(self: Player, recipient: Player, allowedForHumans: boolean): boolean
	if recipient == self then
		return false
	end
	if not self:isAlive() or not recipient:isAlive() or not self:isFriendly(recipient) then
		return false
	end
	if recipient:type() == PlayerType.Human and allowedForHumans == false then
		return false
	end
	for _, d in self.sentDonations do
		if d.recipient == recipient and self.mg:ticks() - d.tick < self.mg:config():donateCooldown() then
			return false
		end
	end
	return true
end

function Player.canDonateGold(self: Player, recipient: Player): boolean
	return self:_canDonate(recipient, self.mg:config():donateGold())
end

function Player.canDonateTroops(self: Player, recipient: Player): boolean
	return self:_canDonate(recipient, self.mg:config():donateTroops())
end

function Player.donateTroops(self: Player, recipient: Player, troops: number): boolean
	if recipient == self or troops <= 0 then
		return false
	end
	local removed = self:removeTroops(troops)
	if removed == 0 then
		return false
	end
	recipient:addTroops(removed)
	table.insert(self.sentDonations, { recipient = recipient, tick = self.mg:ticks() })
	self.mg:addUpdate({ type = "DonateEvent", donationType = "troops", senderId = self:id(), recipientId = recipient:id(), amount = removed })
	return true
end

function Player.donateGold(self: Player, recipient: Player, gold: number): boolean
	if recipient == self or gold <= 0 then
		return false
	end
	local removed = self:removeGold(gold)
	if removed == 0 then
		return false
	end
	local before = recipient:gold()
	recipient:addGold(removed)
	self.mg:stats():goldDonationReceived(recipient, removed, before)
	table.insert(self.sentDonations, { recipient = recipient, tick = self.mg:ticks() })
	self.mg:addUpdate({ type = "DonateEvent", donationType = "gold", senderId = self:id(), recipientId = recipient:id(), amount = removed })
	return true
end

-- PlayerImpl.ts removeAllAlliances (GameImpl.removeAlliancesByPlayerSilently).
function Player.removeAllAlliances(self: Player)
	self.mg:removeAlliancesByPlayerSilently(self)
end

function Player.isAlliedWith(self: Player, other: Player): boolean
	if other == self then
		return false
	end
	for _, a in self._alliances do
		if a:recipient() == other or a:requestor() == other then
			return true
		end
	end
	return false
end

function Player.allianceWith(self: Player, other: Player): any?
	if other == self then
		return nil
	end
	for _, a in self._alliances do
		if a:recipient() == other or a:requestor() == other then
			return a
		end
	end
	return nil
end

function Player.breakAlliance(self: Player, alliance: any)
	self.mg:breakAlliance(self, alliance)
end

function Player.canDeleteUnit(self: Player): boolean
	return self.mg:ticks() - self.lastDeleteUnitTick >= self.mg:config():deleteUnitCooldown()
end

function Player.recordDeleteUnit(self: Player)
	self.lastDeleteUnitTick = self.mg:ticks()
end

function Player.isOnSameTeam(self: Player, other: Player): boolean
	if other == self then
		return false
	end
	local mine, theirs = self:team(), other:team()
	if mine == nil or theirs == nil then
		return false
	end
	if mine == "Bot" or theirs == "Bot" then -- ColoredTeams.Bot
		return false
	end
	return mine == theirs
end

function Player.isFriendly(self: Player, other: Player, treatAFKFriendly: boolean?): boolean
	if other == self then
		return true
	end
	if other:isDisconnected() and not treatAFKFriendly then
		return false
	end
	return self:isOnSameTeam(other) or self:isAlliedWith(other)
end

function Player.isDisconnected(self: Player): boolean
	return self._isDisconnected
end

-- The first disconnect records the team's share of land then (team games
-- read it when a disconnected teammate's land is handed over).
function Player.markDisconnected(self: Player, isDisconnected: boolean, snapshot: { [string]: any }?)
	self._isDisconnected = isDisconnected
	local any = self :: any
	if isDisconnected then
		if any._disconnectSnapshot == nil then
			local team = self:team()
			any._disconnectSnapshot = snapshot
				or {
					currentTick = self.mg:ticks(),
					teamTiles = if team then self.mg:teamTilesOwned(team) else 0,
					totalLand = self.mg:totalLandTiles(),
					wasAlive = self:isAlive(),
				}
		end
	else
		any._disconnectSnapshot = nil
	end
end

function Player.disconnectSnapshot(self: Player): { [string]: any }?
	return (self :: any)._disconnectSnapshot
end

function Player.disconnectedAtTick(self: Player): number?
	local s = (self :: any)._disconnectSnapshot
	return if s then s.currentTick else nil
end

function Player.isTraitor(self: Player): boolean
	return self:getTraitorRemainingTicks() > 0
end

function Player.getTraitorRemainingTicks(self: Player): number
	if self.markedTraitorTick < 0 then
		return 0
	end
	local elapsed = self.mg:ticks() - self.markedTraitorTick
	local remaining = self.mg:config():traitorDuration() - elapsed
	return if remaining > 0 then remaining else 0
end

function Player.markTraitor(self: Player)
	self.markedTraitorTick = self.mg:ticks()
	self._betrayalCount += 1
	self.mg:stats():betray(self)
end

function Player.betrayals(self: Player): number
	return self._betrayalCount
end

function Player.isImmune(self: Player): boolean
	if self:type() == PlayerType.Human then
		return self.mg:isSpawnImmunityActive()
	elseif self:type() == PlayerType.Nation then
		return self.mg:isNationSpawnImmunityActive()
	end
	return false
end

function Player.canAttackPlayer(self: Player, player: Player, treatAFKFriendly: boolean?): boolean
	if self:type() ~= PlayerType.Human then
		-- Only human attackers respect PVP immunity
		return not self:isFriendly(player, treatAFKFriendly)
	end
	return not player:isImmune() and not self:isFriendly(player, treatAFKFriendly)
end

-- PlayerImpl.ts canAttack: an attackable owner, on land, and either sharing a
-- border with us or (free land) joined to our land by free land within 200
-- tiles (Manhattan).
function Player.canAttack(self: Player, tile: number): boolean
	local mg = self.mg
	local owner = mg:owner(tile)
	if owner == self then
		return false
	end
	if owner:isPlayer() and not self:canAttackPlayer(owner) then
		return false
	end
	if not mg:isLand(tile) or mg:isImpassable(tile) then
		return false
	end
	if mg:hasOwner(tile) then
		return self:sharesBorderWith(owner)
	end
	local tx, ty = mg:x(tile), mg:y(tile)
	local reached = mg:bfs(tile, function(gm: any, t: number): boolean
		return not gm:hasOwner(t)
			and gm:isLand(t)
			and not gm:isImpassable(t)
			and math.abs(gm:x(t) - tx) + math.abs(gm:y(t) - ty) <= 200
	end)
	for _, t in reached do
		for _, n in mg:neighbors(t) do
			if mg:owner(n) == self then
				return true
			end
		end
	end
	return false
end

-- Attacks ------------------------------------------------------------------------

function Player.createAttack(self: Player, target: any, troops: number, sourceTile: number?): Attack.Attack
	local attack = Attack.new(self._pseudo_random:nextID(), target, self, troops, sourceTile)
	table.insert(self._outgoingAttacks, attack)
	if target:isPlayer() then
		table.insert(target._incomingAttacks, attack)
	end
	return attack
end

-- The live list (Attack.delete swaps in a new one, so loops over it are safe).
function Player.outgoingAttacks(self: Player): { Attack.Attack }
	return self._outgoingAttacks
end

function Player.incomingAttacks(self: Player): { Attack.Attack }
	local out = {}
	for _, a in self._incomingAttacks do
		if a:attacker():isAlive() then
			table.insert(out, a)
		end
	end
	return out
end

function Player.orderRetreat(self: Player, id: string)
	for _, attack in self._outgoingAttacks do
		if attack:id() == id then
			attack:orderRetreat()
			return
		end
	end
end

function Player.executeRetreat(self: Player, id: string)
	for _, attack in self._outgoingAttacks do
		if attack:id() == id then
			attack:executeRetreat()
			return
		end
	end
end

-- PlayerImpl.ts hash: for determinism checks against OpenFront.
function Player.hash(self: Player): number
	local units = 0
	for _, u in self._units do
		units += u:hash()
	end
	return Util.simpleHash(self:id()) * (self:troops() + self:numTilesOwned()) + units
end

return Player
