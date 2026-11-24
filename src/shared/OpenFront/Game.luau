--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/GameImpl.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The match state and the tick loop. Executions are objects with
-- init(game, ticks), tick(ticks), isActive() and activeDuringSpawnPhase(),
-- exactly as in OpenFront; each tick runs them in insertion order.
-- Phase A subset: players, territory, borders, executions, units by
-- proximity, conquest and the hash. Teams, alliances, water pathing, rail
-- and the client update stream arrive in later phases. Changed tiles are
-- collected for our replication (drainTileUpdates) instead of OpenFront's
-- packed worker messages.

local EngineConfig = require(script.Parent.EngineConfig)
local Alliance = require(script.Parent.Alliance)
local GameMap = require(script.Parent.GameMap)
local GameTypes = require(script.Parent.GameTypes)
local Player = require(script.Parent.Player)
local Stats = require(script.Parent.Stats)
local TeamAssignment = require(script.Parent.TeamAssignment)

-- Land with water beside it (GameMap's IS_LAND | SHORELINE bits): the
-- tiles Player.shoreVersion follows.
local SHORE_LAND = 0xC0
local Unit = require(script.Parent.Unit)
local UnitGrid = require(script.Parent.UnitGrid)
local Util = require(script.Parent.Util)
local WaterManager = require(script.Parent.WaterManager)

local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

export type Execution = {
	init: (self: any, mg: any, ticks: number) -> (),
	tick: (self: any, ticks: number) -> (),
	isActive: (self: any) -> boolean,
	activeDuringSpawnPhase: (self: any) -> boolean,
}

-- TerraNulliusImpl.ts: the "owner" of unowned land.
local TerraNullius = {}
TerraNullius.__index = TerraNullius
function TerraNullius.smallID(_self: any): number
	return 0
end
function TerraNullius.clientID(_self: any): string
	return "TERRA_NULLIUS_CLIENT_ID"
end
function TerraNullius.id(_self: any): nil
	return nil
end
function TerraNullius.isPlayer(_self: any): boolean
	return false
end

local Game = {}
Game.__index = Game

export type Game = typeof(setmetatable(
	{} :: {
		_ticks: number,
		startTick: number?,
		unInitExecs: { any },
		execs: { any },
		_players: { [string]: Player.Player? },
		_playerOrder: { Player.Player }, -- insertion order, like JS Map iteration
		_unitsVersion: number, -- bumped when any player's unit list changes
		_unitsCache: { [string]: { version: number, list: { Unit.Unit } } },
		_unitCountMemo: { [string]: { version: number, count: number } },
		_playersBySmallID: { Player.Player },
		_terraNullius: any,
		_map: GameMap.GameMap,
		_miniMap: GameMap.GameMap?,
		_config: any,
		_stats: Stats.Stats,
		nextPlayerID: number,
		_nextUnitID: number,
		_unitGrid: UnitGrid.UnitGrid,
		_unitMap: { [number]: Unit.Unit },
		allianceRequests: { any },
		_nextAllianceID: number,
		_territoryVersion: number,
		_mirvsLaunched: number,
		_nukeImpacts: { number },
		tileUpdates: { number },
		updates: { any },
		messages: { any },
		_winner: any,
		_isPaused: boolean,
		_waterManager: WaterManager.WaterManager?,
		shipStaggers: { tradeShip: number, transportShip: number },
		_waterChainCache: any,
		_nationList: { any },
		_teamGameSpawnAreas: any?,
		playerTeams: { string },
		botTeam: string,
	},
	Game
))

-- GameImpl.ts createGame / constructor. `humans` are PlayerInfos and
-- `nations` are NationCreation records ({ spawnCell, playerInfo }). Team
-- games resolve their teams first (populateTeams) and add players in
-- assignTeams' order, which sets their smallIDs.
function Game.new(
	humans: { Player.PlayerInfo },
	nations: { { spawnCell: any, playerInfo: Player.PlayerInfo } },
	gameMap: GameMap.GameMap,
	miniGameMap: GameMap.GameMap?,
	config: any,
	teamGameSpawnAreas: any?
): Game
	local self: Game = setmetatable({
		_ticks = 0,
		startTick = nil,
		unInitExecs = {},
		execs = {},
		_players = {},
		_playerOrder = {},
		_unitsVersion = 0,
		_unitsCache = {},
		_unitCountMemo = {},
		_playersBySmallID = {},
		_terraNullius = setmetatable({}, TerraNullius),
		_map = gameMap,
		_miniMap = miniGameMap,
		_config = config,
		_stats = Stats.new(),
		nextPlayerID = 1,
		_nextUnitID = 1,
		_unitGrid = UnitGrid.new(gameMap),
		_unitMap = {},
		allianceRequests = {},
		_nextAllianceID = 0,
		_territoryVersion = 0,
		_mirvsLaunched = 0,
		_nukeImpacts = {},
		tileUpdates = {},
		updates = {},
		messages = {},
		_winner = nil,
		_isPaused = false,
		_waterManager = nil,
		shipStaggers = { tradeShip = 0, transportShip = 0 },
		_waterChainCache = nil,
		_nationList = nations,
		_teamGameSpawnAreas = teamGameSpawnAreas,
		playerTeams = {},
		botTeam = TeamAssignment.ColoredTeams.Bot,
	}, Game) :: any
	-- Ships route on the minimap's water graph (tests may pass no minimap).
	if miniGameMap ~= nil then
		self._waterManager = WaterManager.new(gameMap, miniGameMap, config:disableNavMesh())
	end
	if config:gameConfig().gameMode == GameTypes.GameMode.Team then
		-- populateTeams
		self.playerTeams = TeamAssignment.resolveTeamsList(config:playerTeams(), #humans + #nations)
	end
	self:_addPlayers(humans, nations)
	return self
end

-- GameImpl.ts addPlayers.
function Game._addPlayers(self: Game, humans: { Player.PlayerInfo }, nations: { any })
	local config = self._config
	if config:gameConfig().gameMode ~= GameTypes.GameMode.Team then
		for _, p in humans do
			self:addPlayer(p)
		end
		for _, n in nations do
			self:addPlayer(n.playerInfo)
		end
		return
	end
	local pt = config:playerTeams()
	if pt == GameTypes.HumansVsNations then
		for _, p in humans do
			self:addPlayer(p, TeamAssignment.ColoredTeams.Humans)
		end
		for _, n in nations do
			self:addPlayer(n.playerInfo, TeamAssignment.ColoredTeams.Nations)
		end
		return
	end
	local all = table.clone(humans)
	for _, n in nations do
		table.insert(all, n.playerInfo)
	end
	local isDuosTriosQuads = pt == GameTypes.Duos or pt == GameTypes.Trios or pt == GameTypes.Quads
	for _, a in TeamAssignment.assignTeams(all, self.playerTeams, isDuosTriosQuads) do
		if a.team ~= "kicked" then
			self:addPlayer(a.info, a.team)
		end
	end
end

-- Convenience for tests and the runner: an EngineConfig from a GameConfig.
function Game.config(self: Game): any
	return self._config
end

Game.newConfig = EngineConfig.new

function Game.map(self: Game): GameMap.GameMap
	return self._map
end

function Game.miniMap(self: Game): GameMap.GameMap?
	return self._miniMap
end

function Game.stats(self: Game): Stats.Stats
	return self._stats
end

function Game.terraNullius(self: Game): any
	return self._terraNullius
end

function Game.owner(self: Game, ref: number): any
	return self:playerBySmallID(self._map:ownerID(ref))
end

function Game.playerBySmallID(self: Game, id: number): any
	if id == 0 then
		return self._terraNullius
	end
	return self._playersBySmallID[id]
end

function Game.addUpdate(self: Game, update: any)
	table.insert(self.updates, update)
end

-- GameImpl.ts displayMessage: kept for the event feed (Phase E reads it).
function Game.displayMessage(self: Game, key: string, kind: string, playerId: string?, gold: number?, params: any?)
	table.insert(self.messages, { key = key, kind = kind, playerId = playerId, gold = gold, params = params })
end

-- Messages since the last drain (the server sends each to its player).
function Game.drainMessages(self: Game): { any }
	local out = self.messages
	self.messages = {}
	return out
end

function Game.nextUnitID(self: Game): number
	local id = self._nextUnitID
	self._nextUnitID += 1
	return id
end

function Game.unitInfo(self: Game, unitType: string): { [string]: any }
	return self._config:unitInfo(unitType)
end

function Game.mirvsLaunched(self: Game): number
	return self._mirvsLaunched
end

-- Phase and clock ------------------------------------------------------------

function Game.inSpawnPhase(self: Game): boolean
	return self.startTick == nil
end

function Game.endSpawnPhase(self: Game)
	if self.startTick ~= nil then
		return
	end
	self.startTick = self._ticks
	self:addUpdate({ type = "SpawnPhaseEnd", startTick = self._ticks })
end

function Game.ticks(self: Game): number
	return self._ticks
end

function Game._ticksSinceStart(self: Game): number
	local start = self.startTick
	if start == nil then
		return 0
	end
	return math.max(0, self._ticks - start)
end

function Game.isSpawnImmunityActive(self: Game): boolean
	return self:inSpawnPhase() or self:_ticksSinceStart() < self._config:spawnImmunityDuration()
end

function Game.isNationSpawnImmunityActive(self: Game): boolean
	return self:inSpawnPhase() or self:_ticksSinceStart() < self._config:nationSpawnImmunityDuration()
end

function Game.elapsedGameSeconds(self: Game): number
	return self:_ticksSinceStart() / 10
end

-- GameImpl.ts executeNextTick
function Game.executeNextTick(self: Game)
	self.updates = {}
	local spawnPhase = self:inSpawnPhase()
	-- The loop walks the array as it was; additions go to unInitExecs.
	local execs = self.execs
	for i = 1, #execs do
		local e = execs[i]
		if (not spawnPhase or e:activeDuringSpawnPhase()) and e:isActive() then
			e:tick(self._ticks)
		end
	end
	local inited, unInited = {}, {}
	for _, e in self.unInitExecs do
		if not self:inSpawnPhase() or e:activeDuringSpawnPhase() then
			e:init(self, self._ticks)
			table.insert(inited, e)
		else
			table.insert(unInited, e)
		end
	end

	self:removeInactiveExecutions()

	for _, e in inited do
		table.insert(self.execs, e)
	end
	self.unInitExecs = unInited
	for _, player in self._playerOrder do
		if player:isAlive() and player:hasSpawned() then
			self._stats:recordTickSample(player, player:numTilesOwned(), player:troops(), #player:alliances())
		end
	end
	-- Flush pending water conversions (throttled graph rebuild).
	local wm = self._waterManager
	if wm ~= nil then
		for _, tile in wm:tick(self._ticks) do
			table.insert(self.tileUpdates, tile)
		end
	end
	self._ticks += 1
end

function Game.removeInactiveExecutions(self: Game)
	local spawnPhase = self:inSpawnPhase()
	local kept = {}
	for _, exec in self.execs do
		local keep = if spawnPhase then (not exec:activeDuringSpawnPhase() or exec:isActive()) else exec:isActive()
		if keep then
			table.insert(kept, exec)
		end
	end
	self.execs = kept
end

function Game.executions(self: Game): { any }
	local out = table.clone(self.execs)
	for _, e in self.unInitExecs do
		table.insert(out, e)
	end
	return out
end

function Game.addExecution(self: Game, ...: any)
	for _, e in { ... } do
		table.insert(self.unInitExecs, e)
	end
end

function Game.removeExecution(self: Game, exec: any)
	local function without(list: { any }): { any }
		local out = {}
		for _, e in list do
			if e ~= exec then
				table.insert(out, e)
			end
		end
		return out
	end
	self.execs = without(self.execs)
	self.unInitExecs = without(self.unInitExecs)
end

-- Players ------------------------------------------------------------------------

function Game.addPlayer(self: Game, playerInfo: Player.PlayerInfo, team: any?): Player.Player
	local player = Player.new(self, self.nextPlayerID, playerInfo, self._config:startManpower(playerInfo), team or self:_maybeAssignTeam(playerInfo))
	table.insert(self._playersBySmallID, player)
	self.nextPlayerID += 1
	if self._players[playerInfo.id] == nil then
		table.insert(self._playerOrder, player)
		self._unitsVersion += 1
	end
	self._players[playerInfo.id] = player
	return player
end

-- GameImpl.ts maybeAssignTeam: tribes join the Bot team; anyone else added
-- later lands on a team by the hash of their id.
function Game._maybeAssignTeam(self: Game, info: Player.PlayerInfo): string?
	if self._config:gameConfig().gameMode ~= GameTypes.GameMode.Team then
		return nil
	end
	if info.playerType == GameTypes.PlayerType.Bot then
		return self.botTeam
	end
	local teams = self.playerTeams
	return teams[Util.simpleHash(info.id) % #teams + 1]
end

-- GameImpl.ts teams: the Bot team, then the player teams (Team games only).
function Game.teams(self: Game): { string }
	if self._config:gameConfig().gameMode ~= GameTypes.GameMode.Team then
		return {}
	end
	local out = { self.botTeam }
	for _, t in self.playerTeams do
		table.insert(out, t)
	end
	return out
end

function Game.player(self: Game, id: string): Player.Player
	local player = self._players[id]
	if player == nil then
		error(`Player with id {id} not found`)
	end
	return player
end

function Game.playerByClientID(self: Game, clientID: string): Player.Player?
	for _, p in self._playerOrder do
		if p:clientID() == clientID then
			return p
		end
	end
	return nil
end

function Game.hasPlayer(self: Game, id: string?): boolean
	return id ~= nil and self._players[id] ~= nil
end

-- Alive players, in join order.
function Game.players(self: Game): { Player.Player }
	local out = {}
	for _, p in self._playerOrder do
		if p:isAlive() then
			table.insert(out, p)
		end
	end
	return out
end

function Game.allPlayers(self: Game): { Player.Player }
	return table.clone(self._playerOrder)
end

-- Territory ----------------------------------------------------------------------

function Game.conquer(self: Game, owner: Player.Player, tile: number)
	local map = self._map
	if not map:isLand(tile) then
		error("cannot conquer water")
	end
	if map:isImpassable(tile) then
		error("cannot conquer impassable terrain")
	end
	local previousOwner = self:owner(tile)
	if previousOwner:isPlayer() then
		previousOwner._lastTileChange = self._ticks
		previousOwner._tileChangeVersion += 1
		previousOwner._tiles:delete(tile)
		if previousOwner._borderTiles:delete(tile) and bit32.band(buffer.readu8(map.terrain, tile), SHORE_LAND) == SHORE_LAND then
			previousOwner._shoreVersion += 1
		end
	end
	self._territoryVersion += 1
	map:setOwnerID(tile, owner:smallID())
	owner._tiles:add(tile)
	owner._lastTileChange = self._ticks
	owner._tileChangeVersion += 1
	self:_updateBorders(tile)
	map:setFallout(tile, false)
	table.insert(self.tileUpdates, tile)
end

function Game.relinquish(self: Game, tile: number)
	local map = self._map
	if not map:hasOwner(tile) then
		error("Cannot relinquish tile because it is unowned")
	end
	if map:isWater(tile) then
		error("Cannot relinquish water")
	end
	local previousOwner = self:owner(tile)
	previousOwner._lastTileChange = self._ticks
	previousOwner._tileChangeVersion += 1
	previousOwner._tiles:delete(tile)
	if previousOwner._borderTiles:delete(tile) and bit32.band(buffer.readu8(map.terrain, tile), SHORE_LAND) == SHORE_LAND then
		previousOwner._shoreVersion += 1
	end
	self._territoryVersion += 1
	map:setOwnerID(tile, 0)
	self:_updateBorders(tile)
	table.insert(self.tileUpdates, tile)
end

local PLAYER_ID_MASK = GameMap.PLAYER_ID_MASK

-- _updateBorderStatus over the state buffer: it runs for every captured tile
-- and its neighbours, so method calls per probe were a large share of the
-- tick. Same adds and deletes in the same order (TileSet order matters).
local function updateBorderStatus(players: { [number]: any }, state: buffer, terrain: buffer, w: number, lastRow: number, t: number)
	local owner = bit32.band(buffer.readu16(state, t * 2), PLAYER_ID_MASK)
	if owner == 0 then
		return
	end
	local x = t % w
	local border = (x ~= 0 and bit32.band(buffer.readu16(state, (t - 1) * 2), PLAYER_ID_MASK) ~= owner)
		or (x ~= w - 1 and bit32.band(buffer.readu16(state, (t + 1) * 2), PLAYER_ID_MASK) ~= owner)
		or (t >= w and bit32.band(buffer.readu16(state, (t - w) * 2), PLAYER_ID_MASK) ~= owner)
		or (t < lastRow and bit32.band(buffer.readu16(state, (t + w) * 2), PLAYER_ID_MASK) ~= owner)
	local player = players[owner]
	local set = player._borderTiles
	if border then
		if set.slot[t] == nil then
			set:add(t)
			if bit32.band(buffer.readu8(terrain, t), SHORE_LAND) == SHORE_LAND then
				player._shoreVersion += 1
			end
		end
	elseif set.slot[t] ~= nil then
		set:delete(t)
		if bit32.band(buffer.readu8(terrain, t), SHORE_LAND) == SHORE_LAND then
			player._shoreVersion += 1
		end
	end
end

function Game._updateBorders(self: Game, tile: number)
	local map = self._map
	local players, state, terrain, w = self._playersBySmallID, map.state, map.terrain, map.width_
	local lastRow = (map.height_ - 1) * w
	updateBorderStatus(players, state, terrain, w, lastRow, tile)
	-- neighbors4 order: north, south, west, east.
	if tile >= w then
		updateBorderStatus(players, state, terrain, w, lastRow, tile - w)
	end
	if tile < lastRow then
		updateBorderStatus(players, state, terrain, w, lastRow, tile + w)
	end
	local x = tile % w
	if x ~= 0 then
		updateBorderStatus(players, state, terrain, w, lastRow, tile - 1)
	end
	if x ~= w - 1 then
		updateBorderStatus(players, state, terrain, w, lastRow, tile + 1)
	end
end

-- TileTraversalScratch.ts: one visited-generation array per game, shared by
-- every flood fill. A pass marks visited[t] = gen; bumping gen clears all
-- marks at once.
export type TraversalScratch = { visited: buffer, stack: { number }, clusterIndexMap: buffer, gen: number }

function Game.traversalScratch(self: Game): TraversalScratch
	local any = self :: any
	local scratch = any._scratch
	if scratch == nil then
		local n = self._map:width() * self._map:height()
		scratch = { visited = buffer.create(n * 4), stack = {}, clusterIndexMap = buffer.create(n * 4), gen = 0 }
		any._scratch = scratch
	end
	return scratch
end

function Game.bumpTraversalGeneration(self: Game): number
	local scratch = self:traversalScratch()
	scratch.gen += 1
	if scratch.gen == 0xffffffff then
		buffer.fill(scratch.visited, 0, 0)
		scratch.gen = 1
	end
	return scratch.gen
end

-- Tiles whose owner changed since the last drain, in change order.
function Game.drainTileUpdates(self: Game): { number }
	local out = self.tileUpdates
	self.tileUpdates = {}
	return out
end

function Game.territoryVersion(self: Game): number
	return self._territoryVersion
end

-- GameImpl.ts conquerPlayer: gold changes hands when a player is wiped out;
-- a disconnected teammate's warships and boats join the conqueror.
function Game.conquerPlayer(self: Game, conqueror: Player.Player, conquered: Player.Player)
	if conquered:isDisconnected() and conqueror:isOnSameTeam(conquered) then
		for _, ship in conquered:units({ UnitType.Warship, UnitType.TransportShip }) do
			conqueror:captureUnit(ship)
		end
	end
	-- No gold for beating a human who never sent an attack.
	local skipGoldTransfer = self._stats:attacksSentBy(conquered) == 0 and conquered:type() == PlayerType.Human
	local gold = if skipGoldTransfer then 0 else conquered:gold()
	local goldCaptured = if skipGoldTransfer then 0 else self._config:conquerGoldAmount(conquered)
	if skipGoldTransfer then
		self:displayMessage("events_display.conquered_no_gold", "CONQUERED_PLAYER", conqueror:id(), nil, {
			name = conquered:displayName(),
		})
	else
		self:displayMessage("events_display.received_gold_from_conquest", "CONQUERED_PLAYER", conqueror:id(), gold, {
			gold = goldCaptured,
			name = conquered:displayName(),
		})
		conqueror:addGold(goldCaptured)
		conquered:removeGold(gold)
		self._stats:goldWar(conqueror, conquered, goldCaptured)
	end
	-- Conquest's Arsenal: who eliminated whom, for a Takeover (Runner.takeOver).
	(conquered :: any)._conqueredBy = conqueror
	self._stats:recordKill(conqueror, conquered, self._ticks)
	self._stats:recordKilledBy(conquered, conqueror:clientID())
	local alive = 0
	for _, p in self:players() do
		if p ~= conquered and p:type() ~= PlayerType.Bot then
			alive += 1
		end
	end
	self._stats:recordDeathPosition(conquered, alive + 1)
	self:addUpdate({ type = "ConquestEvent", conquerorId = conqueror:id(), conqueredId = conquered:id(), gold = goldCaptured })
	-- Conquest: the Runner adds the public cosmetic mark (it knows the names).
	local hook = (self :: any).onConquest
	if hook then
		hook(conqueror, conquered)
	end
end

-- Units ------------------------------------------------------------------------

-- GameImpl.ts addUnit/removeUnit/updateUnitTile: the grid and the id map.
function Game.addUnit(self: Game, u: Unit.Unit)
	self._unitGrid:addUnit(u)
	self._unitMap[u:id()] = u
end

function Game.removeUnit(self: Game, u: Unit.Unit)
	self._unitGrid:removeUnit(u)
	self._unitMap[u:id()] = nil
	if u:hasTrainStation() then
		self:railNetwork():removeStation(u)
	end
end

-- GameImpl.ts railNetwork (created on first use; it needs the minimap).
function Game.railNetwork(self: Game): any
	local any = self :: any
	if any._railNetwork == nil then
		any._railNetwork = require(script.Parent.Rail).RailNetwork.new(self)
	end
	return any._railNetwork
end

function Game.onUnitMoved(self: Game, u: Unit.Unit)
	self._unitGrid:updateUnitCell(u)
end

function Game.unit(self: Game, id: number): Unit.Unit?
	return self._unitMap[id]
end

-- Alliances (GameImpl.ts) -------------------------------------------------------------

local function removeFrom(list: { any }, item: any): { any }
	local out = {}
	for _, v in list do
		if v ~= item then
			table.insert(out, v)
		end
	end
	return out
end

-- A new request, or nil: already allied, a duplicate, or the recipient had
-- already asked us (then that request is accepted instead).
function Game.createAllianceRequest(self: Game, requestor: Player.Player, recipient: Player.Player): any?
	if requestor:isAlliedWith(recipient) then
		return nil
	end
	for _, ar in recipient:incomingAllianceRequests() do
		if ar:requestor() == requestor then
			return nil
		end
	end
	for _, ar in requestor:incomingAllianceRequests() do
		if ar:requestor() == recipient then
			ar:accept()
			return nil
		end
	end
	local ar = Alliance.Request.new(requestor, recipient, self._ticks, self)
	table.insert(self.allianceRequests, ar)
	self:addUpdate(ar:toUpdate())
	return ar
end

function Game.acceptAllianceRequest(self: Game, request: any)
	self.allianceRequests = removeFrom(self.allianceRequests, request)
	local requestor, recipient = request:requestor(), request:recipient()
	if requestor:allianceWith(recipient) then
		error(`cannot accept alliance request, already allied with {recipient:name()}`)
	end
	local alliance = Alliance.new(self, requestor, recipient, self._ticks, self._nextAllianceID)
	self._nextAllianceID += 1
	table.insert(requestor._alliances, alliance)
	table.insert(recipient._alliances, alliance)
	self._stats:allianceFormed(requestor)
	self._stats:allianceFormed(recipient)
	table.insert(requestor.pastOutgoingAllianceRequests, request)
	self:addUpdate({ type = "AllianceRequestReply", request = request:toUpdate(), accepted = true })
end

function Game.rejectAllianceRequest(self: Game, request: any)
	self.allianceRequests = removeFrom(self.allianceRequests, request)
	table.insert(request:requestor().pastOutgoingAllianceRequests, request)
	self:addUpdate({ type = "AllianceRequestReply", request = request:toUpdate(), accepted = false })
end

-- Breaking marks the breaker a traitor, unless the other side is a traitor
-- or disconnected.
function Game.breakAlliance(self: Game, breaker: Player.Player, alliance: any)
	local other = if alliance:requestor() == breaker then alliance:recipient() else alliance:requestor()
	if not breaker:isAlliedWith(other) then
		error(`{breaker:name()} not allied with {other:name()}, cannot break alliance`)
	end
	local duration = self._ticks - alliance:createdAt()
	if not other:isTraitor() and not other:isDisconnected() then
		breaker:markTraitor()
		self._stats:allianceEnded(other, duration, "brokenByOther")
	else
		self._stats:allianceEnded(other, duration, nil)
	end
	self._stats:allianceEnded(breaker, duration, nil)
	self:_detachAlliance(alliance)
	self:addUpdate({ type = "BrokeAlliance", traitorID = breaker:smallID(), betrayedID = other:smallID(), allianceID = alliance:id() })
end

function Game.expireAlliance(self: Game, alliance: any)
	local recipientSet = {}
	for _, a in alliance:recipient():alliances() do
		recipientSet[a] = true
	end
	local shared = {}
	for _, a in alliance:requestor():alliances() do
		if recipientSet[a] then
			table.insert(shared, a)
		end
	end
	if #shared ~= 1 then
		error(`cannot expire alliance: must have exactly one alliance, have {#shared}`)
	end
	local expiring = shared[1]
	local duration = self._ticks - expiring:createdAt()
	self._stats:allianceEnded(expiring:requestor(), duration, "expired")
	self._stats:allianceEnded(expiring:recipient(), duration, "expired")
	self:_detachAlliance(expiring)
	self:addUpdate({ type = "AllianceExpired", player1ID = alliance:requestor():smallID(), player2ID = alliance:recipient():smallID() })
end

-- Elimination: alliances end with no traitor and nothing expired.
function Game.removeAlliancesByPlayerSilently(self: Game, player: Player.Player)
	for _, alliance in table.clone(player._alliances) do
		local duration = self._ticks - alliance:createdAt()
		self._stats:allianceEnded(alliance:requestor(), duration, nil)
		self._stats:allianceEnded(alliance:recipient(), duration, nil)
		self:_detachAlliance(alliance)
	end
end

function Game._detachAlliance(_self: Game, alliance: any)
	local requestor, recipient = alliance:requestor(), alliance:recipient()
	requestor._alliances = removeFrom(requestor._alliances, alliance)
	recipient._alliances = removeFrom(recipient._alliances, alliance)
end

-- GameImpl.ts sharedWaterComponents (SharedWaterCache): comp -> true, or nil.
function Game.sharedWaterComponents(self: Game, player: any): { [number]: boolean }?
	local any = self :: any
	if any._sharedWaterCache == nil then
		any._sharedWaterCache = require(script.Parent.Executions.Nation.SharedWaterCache).new(self)
	end
	return any._sharedWaterCache:get(player)
end

function Game.isOcean(self: Game, ref: number): boolean
	return self._map:isOcean(ref)
end

function Game.magnitude(self: Game, ref: number): number
	return self._map:magnitude(ref)
end

-- GameImpl.ts nationMirvTargets: player id -> tick a nation last MIRVed them.
function Game.nationMirvTargets(self: Game): { [string]: number }
	local any = self :: any
	any._nationMirvTargets = any._nationMirvTargets or {}
	return any._nationMirvTargets
end

function Game.teamTilesOwned(self: Game, team: any): number
	local n = 0
	for _, p in self:allPlayers() do
		if p:team() == team then
			n += p:numTilesOwned()
		end
	end
	return n
end

function Game.totalLandTiles(self: Game): number
	return math.max(0, self:numLandTiles() - self:numTilesWithFallout())
end

function Game.displayChat(self: Game, message: string, category: string, target: string?, playerID: string?, isFrom: boolean, recipient: string)
	local id = if playerID ~= nil then self:player(playerID):smallID() else nil
	self:addUpdate({ type = "DisplayChatEvent", key = message, category = category, target = target, playerID = id, isFrom = isFrom, recipient = recipient })
end

function Game.target(self: Game, targeter: Player.Player, target: Player.Player)
	self:addUpdate({ type = "TargetPlayer", playerID = targeter:smallID(), targetID = target:smallID() })
end

function Game.sendEmojiUpdate(self: Game, msg: any)
	self:addUpdate({ type = "Emoji", emoji = msg })
end

-- GameImpl.ts units: every player's units in player order, each player's own
-- list order; filtered to the given types if any.
-- Conquest (performance, exact): every nation asks for these lists every
-- tick, and building one walks every player's units. The result is cached by
-- type list and rebuilt only after a unit list changes (Game._unitsChanged:
-- a unit built, captured or deleted, or a player added), so callers get the
-- same units in the same order as a fresh walk. Callers get a copy.
function Game._unitsChanged(self: Game)
	self._unitsVersion += 1
end

function Game.units(self: Game, ...: string): { Unit.Unit }
	local types = { ... }
	local key = table.concat(types, "|")
	local cached = self._unitsCache[key]
	if cached and cached.version == self._unitsVersion then
		return table.clone(cached.list)
	end
	local wanted: { [string]: true }? = nil
	if #types > 0 then
		local set: { [string]: true } = {}
		for _, t in types do
			set[t] = true
		end
		wanted = set
	end
	local out = {}
	for _, p in self._playerOrder do
		for _, u in p:units() do
			if wanted == nil or wanted[u:type()] then
				table.insert(out, u)
			end
		end
	end
	self._unitsCache[key] = { version = self._unitsVersion, list = out }
	return table.clone(out)
end

-- Level-weighted count of one type across every player. Memoised per
-- unit-list version, as GameImpl.ts does (unitCountMemo): every SAM, port and
-- train station asks each tick, and a walk covers every player's units. The
-- version also moves when a unit's level does (Unit.increaseLevel).
function Game.unitCount(self: Game, unitType: string): number
	local memo = self._unitCountMemo[unitType]
	if memo ~= nil and memo.version == self._unitsVersion then
		return memo.count
	end
	local total = 0
	for _, p in self._playerOrder do
		total += p:unitCount(unitType)
	end
	self._unitCountMemo[unitType] = { version = self._unitsVersion, count = total }
	return total
end

-- MotionPlans.ts records: full paths for the client to animate.
function Game.recordMotionPlan(self: Game, record: any)
	local any = self :: any
	any._motionPlans = any._motionPlans or {}
	table.insert(any._motionPlans, record)
end

function Game.drainMotionPlans(self: Game): { any }
	local any = self :: any
	local plans = any._motionPlans or {}
	any._motionPlans = {}
	return plans
end

function Game.displayIncomingUnit(self: Game, unitId: number, key: string, kind: string, playerId: string)
	self:displayMessage(key, kind, playerId, nil, { unitId = unitId })
end

function Game.hasUnitNearby(
	self: Game,
	tile: number,
	searchRange: number,
	unitType: string,
	playerId: string?,
	includeUnderConstruction: boolean?
): boolean
	return self._unitGrid:hasUnitNearby(tile, searchRange, unitType, playerId, includeUnderConstruction)
end

function Game.nearbyUnits(
	self: Game,
	tile: number,
	searchRange: number,
	types: string | { string },
	predicate: ((any) -> boolean)?,
	includeUnderConstruction: boolean?
): { UnitGrid.Nearby }
	return self._unitGrid:nearbyUnits(tile, searchRange, types, predicate, includeUnderConstruction)
end

function Game.anyUnitNearby(
	self: Game,
	tile: number,
	searchRange: number,
	types: { string },
	predicate: (any) -> boolean,
	playerId: string?,
	includeUnderConstruction: boolean?
): boolean
	return self._unitGrid:anyUnitNearby(tile, searchRange, types, predicate, playerId, includeUnderConstruction)
end

-- Map delegates used by executions --------------------------------------------

function Game.ref(self: Game, x: number, y: number): number
	return self._map:ref(x, y)
end
function Game.x(self: Game, ref: number): number
	return self._map:x(ref)
end
function Game.y(self: Game, ref: number): number
	return self._map:y(ref)
end
function Game.width(self: Game): number
	return self._map:width()
end
function Game.height(self: Game): number
	return self._map:height()
end
function Game.isLand(self: Game, ref: number): boolean
	return self._map:isLand(ref)
end
function Game.isWater(self: Game, ref: number): boolean
	return self._map:isWater(ref)
end
function Game.isImpassable(self: Game, ref: number): boolean
	return self._map:isImpassable(ref)
end
function Game.hasOwner(self: Game, ref: number): boolean
	return self._map:hasOwner(ref)
end
function Game.hasFallout(self: Game, ref: number): boolean
	return self._map:hasFallout(ref)
end
function Game.numTilesWithFallout(self: Game): number
	return self._map:numTilesWithFallout()
end
function Game.numLandTiles(self: Game): number
	return self._map:numLandTiles()
end
function Game.terrainType(self: Game, ref: number): number
	return self._map:terrainType(ref)
end
function Game.forEachNeighbor(self: Game, ref: number, fn: (number) -> ())
	self._map:forEachNeighbor(ref, fn)
end
function Game.neighbors(self: Game, ref: number): { number }
	return self._map:neighbors(ref)
end

function Game.isValidRef(self: Game, ref: number): boolean
	return self._map:isValidRef(ref)
end
function Game.isValidCoord(self: Game, x: number, y: number): boolean
	return self._map:isValidCoord(x, y)
end
function Game.isBorder(self: Game, ref: number): boolean
	return self._map:isBorder(ref)
end
function Game.isShore(self: Game, ref: number): boolean
	return self._map:isShore(ref)
end
function Game.isOceanShore(self: Game, ref: number): boolean
	return self._map:isOceanShore(ref)
end
function Game.manhattanDist(self: Game, a: number, b: number): number
	return self._map:manhattanDist(a, b)
end
function Game.euclideanDistSquared(self: Game, a: number, b: number): number
	return self._map:euclideanDistSquared(a, b)
end
function Game.ownerID(self: Game, ref: number): number
	return self._map:ownerID(ref)
end
-- Tiles reached from `tile` through `filter`, in OpenFront's BFS order.
function Game.bfs(self: Game, tile: number, filter: (any, number) -> boolean): { number }
	local order = self._map:bfs(tile, filter)
	return order
end


-- The game's AI nations (NationCreation records).
function Game.nations(self: Game): { any }
	return self._nationList
end

-- Team spawn areas from the map manifest (teams arrive with modes).
-- GameImpl.ts teamSpawnArea: the map's area for this team, from the
-- manifest's areas for this many teams.
function Game.teamSpawnArea(self: Game, team: any): any?
	local areasByCount = self._teamGameSpawnAreas
	if not areasByCount then
		return nil
	end
	local areas = areasByCount[tostring(#self.playerTeams)]
	if not areas then
		return nil
	end
	local index = table.find(self.playerTeams, team)
	if index == nil or index > #areas then
		return nil
	end
	return areas[index]
end

function Game.setWinner(self: Game, winner: any)
	self._winner = winner
	self:addUpdate({ type = "Win", winner = winner })
end

-- GameImpl.ts isPaused / setPaused (the runner stops turns while paused).
function Game.isPaused(self: Game): boolean
	return self._isPaused
end

function Game.setPaused(self: Game, paused: boolean)
	self._isPaused = paused
	self:addUpdate({ type = "GamePaused", paused = paused })
end

function Game.getWinner(self: Game): any
	return self._winner
end

-- Water graph and ships ----------------------------------------------------------

function Game.waterGraphVersion(self: Game): number
	local wm = self._waterManager
	return if wm then wm:waterGraphVersion() else 0
end
function Game.miniWaterHPA(self: Game): any?
	local wm = self._waterManager
	return if wm then wm:miniWaterHPA() else nil
end
function Game.miniWaterGraph(self: Game): any?
	local wm = self._waterManager
	return if wm then wm:miniWaterGraph() else nil
end
function Game.getWaterComponent(self: Game, tile: number): number?
	local wm = self._waterManager
	return if wm then wm:getWaterComponent(tile) else 0
end
function Game.hasWaterComponent(self: Game, tile: number, component: number): boolean
	local wm = self._waterManager
	return if wm then wm:hasWaterComponent(tile, component) else true
end
function Game.getWaterComponentSize(self: Game, tile: number): number?
	local wm = self._waterManager
	return if wm then wm:getWaterComponentSize(tile) else 0
end
-- GameImpl.ts queueWaterConversion: a nuked land tile becomes fallout, or
-- water when the water-nukes modifier is on.
function Game.queueWaterConversion(self: Game, tile: number)
	if not self:isLand(tile) then
		return
	end
	if self:hasOwner(tile) then
		error(`cannot queue water conversion, tile {tile} has owner`)
	end
	if not self._config:waterNukes() then
		self:setFallout(tile, true)
		return
	end
	local wm = self._waterManager
	if wm then
		wm:queueTile(tile)
	end
end

function Game.setFallout(self: Game, tile: number, value: boolean)
	if value and self:hasOwner(tile) then
		error(`cannot set fallout, tile {tile} has owner`)
	end
	if self._map:hasFallout(tile) then
		return
	end
	self._territoryVersion += 1
	self._map:setFallout(tile, value)
	table.insert(self.tileUpdates, tile)
end

-- Every tile in a blast, for the client's nuke effects.
function Game.queueNukeImpact(self: Game, tile: number)
	table.insert(self._nukeImpacts, tile)
end

function Game.drainNukeImpacts(self: Game): { number }
	local out = self._nukeImpacts
	self._nukeImpacts = {}
	return out
end

function Game.recordMirvLaunch(self: Game)
	self._mirvsLaunched += 1
end

function Game.circleSearch(self: Game, tile: number, radius: number, filter: ((number, number) -> boolean)?): { number }
	return self._map:circleSearch(tile, radius, filter)
end
-- Spreads ships' pathfinder rebuilds over STAGGER_SPREAD ticks.
function Game.nextShipStagger(self: Game, kind: string): number
	local v = (self.shipStaggers :: any)[kind]
	;(self.shipStaggers :: any)[kind] = v + 1
	return v % 50
end

-- GameImpl.ts hash: sum of player hashes, for determinism checks.
function Game.hash(self: Game): number
	local hash = 1
	for _, p in self._playerOrder do
		hash += p:hash()
	end
	return hash
end

Game.UnitType = UnitType

return Game
