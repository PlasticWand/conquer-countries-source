--!strict
-- The client's confirmed view of an OpenFront match, rebuilt from the
-- server's snapshot and per-tick deltas (OpenFront/Replication.luau).
-- The renderer and HUD read it and listen to its signals; nothing here
-- decides an outcome. Pure (Lune-tested): the client adapter feeds it remote
-- payloads.
--   tileState: u16 per tile (owner bits 0..11, fallout 13, defence 14)
--   roster:    players by smallID, plus rosterOrder (arrival order, for colours)
--   stats:     tiles/troops/alive/spawnTile/gold per smallID
--   units:     records by id (Replication unitRecord); boats, trade ships,
--              nukes and trains take each tick's tile from their motion
--              plan (MotionPlanResolver), so unit.tile is always current
--   railroads: tiles by railroad id
--   players[i].allies / .embargoes: public relations, as smallIDs, plus
--              .traitor and .disconnected
--   costs:     what each build-bar unit costs you now (by unit type)
--   diplomacy: your alliances ({ id, other, createdAt, expiresAt,
--              extensionRequested }) and pending requests (incoming
--              { requestor, createdAt }, outgoing { recipient, createdAt })
--   names:     name anchors by smallID ({ x, y, size }, GameRunner's
--              placements), replaced whenever the server recomputes them
--   units[i].constructionStartTick: when construction started

local EngineConfig = require(script.Parent.EngineConfig)
local MotionPlanResolver = require(script.Parent.MotionPlanResolver)
local Replication = require(script.Parent.Replication)
local Signal = require(script.Parent.Parent.Signal)

local ClientState = {}
ClientState.__index = ClientState

export type PlayerView = {
	smallID: number,
	id: string,
	name: string,
	displayName: string,
	type: string,
	team: any,
	flag: string?, -- a nation's country code, or a human's flag id (Conquest store)
	skin: string?, -- a human's territory skin id (Store/Skins)
	userId: number?, -- a human's Roblox user id (head shot); nil for bots and nations
	tiles: number,
	troops: number,
	maxTroops: number,
	gold: number,
	alive: boolean,
	spawnTile: number?,
	allies: { number },
	embargoes: { number },
	traitor: boolean,
	disconnected: boolean,
	allyExpiry: { number },
	betrayals: number,
	traitorUntil: number?,
}

export type Diplomacy = {
	alliances: { { id: number, other: number, createdAt: number, expiresAt: number, extensionRequested: boolean } },
	incoming: { { requestor: number, createdAt: number } },
	outgoing: { { recipient: number, createdAt: number } },
}

export type NameAnchor = { x: number, y: number, size: number }

export type ClientState = typeof(setmetatable(
	{} :: {
		ready: boolean,
		gameID: string?,
		tick: number,
		mapName: string?,
		mapFolder: string?,
		mapSize: string?,
		gameConfig: { [string]: any },
		_config: any,
		paused: boolean,
		width: number,
		height: number,
		startTick: number?,
		-- Conquest: the solo deploy countdown's end tick, once you've placed.
		deployDeadline: number?,
		winner: any,
		landTotal: number,
		you: number,
		gold: number,
		tileState: buffer,
		players: { [number]: PlayerView },
		rosterOrder: { number },
		units: { [number]: { [string]: any } },
		plans: MotionPlanResolver.MotionPlanResolver,
		railroads: { [number]: { number } },
		attacks: { { [string]: any } },
		names: { [number]: NameAnchor },
		diplomacy: Diplomacy,
		costs: { [string]: number },
		arsenal: { weapons: { [string]: boolean }, reinforceReadyAt: number, takeover: { smallID: number, name: string }? }?,
		Snapshot: Signal.Signal<>,
		Rebound: Signal.Signal<>,
		TilesChanged: Signal.Signal<{ number }>,
		RosterChanged: Signal.Signal<{ number }>,
		StatsChanged: Signal.Signal<>,
		UnitsChanged: Signal.Signal<{ { [string]: any } }, { number }>,
		PlansArrived: Signal.Signal<{ any }>,
		UnitsMoved: Signal.Signal<{ number }>,
		RailroadsChanged: Signal.Signal<{ number }, { number }>,
		Bonus: Signal.Signal<{ any }>,
		AttacksChanged: Signal.Signal<>,
		PhaseChanged: Signal.Signal<>,
		Messages: Signal.Signal<{ any }>,
		TickApplied: Signal.Signal<number>,
		RelationsChanged: Signal.Signal<{ number }>,
		NamesChanged: Signal.Signal<>,
		DiplomacyChanged: Signal.Signal<>,
		DiplomacyEvents: Signal.Signal<{ any }>,
	},
	ClientState
))

function ClientState.new(): ClientState
	return setmetatable({
		ready = false,
		gameID = nil,
		tick = 0,
		mapName = nil,
		mapFolder = nil,
		mapSize = nil,
		gameConfig = {},
		_config = nil,
		paused = false,
		width = 0,
		height = 0,
		startTick = nil,
		deployDeadline = nil,
		winner = nil,
		landTotal = 0,
		you = 0,
		gold = 0,
		tileState = buffer.create(0),
		players = {},
		rosterOrder = {},
		units = {},
		plans = MotionPlanResolver.new(),
		railroads = {},
		attacks = {},
		names = {},
		diplomacy = { alliances = {}, incoming = {}, outgoing = {} },
		costs = {},
		arsenal = nil,
		Snapshot = Signal.new(),
		Rebound = Signal.new(),
		TilesChanged = Signal.new(),
		RosterChanged = Signal.new(),
		StatsChanged = Signal.new(),
		UnitsChanged = Signal.new(),
		PlansArrived = Signal.new(),
		UnitsMoved = Signal.new(),
		RailroadsChanged = Signal.new(),
		Bonus = Signal.new(),
		AttacksChanged = Signal.new(),
		PhaseChanged = Signal.new(),
		Messages = Signal.new(),
		TickApplied = Signal.new(),
		RelationsChanged = Signal.new(),
		NamesChanged = Signal.new(),
		DiplomacyChanged = Signal.new(),
		DiplomacyEvents = Signal.new(),
	}, ClientState)
end

local function addRoster(self: ClientState, entries: { any }): { number }
	local added = {}
	for _, e in entries do
		local known = self.players[e.smallID]
		if known ~= nil then
			-- A changed entry (a Takeover): what it shows, every field set
			-- (nil clears); stats, relations and the capital stay.
			known.id = e.id
			known.name = e.name
			known.displayName = e.displayName or e.name
			known.type = e.type
			known.team = e.team
			known.flag = e.flag
			known.skin = e.skin
			known.userId = e.userId
			table.insert(added, e.smallID)
			continue
		end
		table.insert(self.rosterOrder, e.smallID)
		table.insert(added, e.smallID)
		self.players[e.smallID] = {
			smallID = e.smallID,
			id = e.id,
			name = e.name,
			displayName = e.displayName or e.name,
			type = e.type,
			team = e.team,
			flag = e.flag,
			skin = e.skin,
			userId = e.userId,
			tiles = 0,
			troops = 0,
			maxTroops = 0,
			gold = 0,
			alive = false,
			spawnTile = nil,
			allies = {},
			embargoes = {},
			traitor = false,
			disconnected = false,
			allyExpiry = {},
			betrayals = 0,
			traitorUntil = nil,
		}
	end
	return added
end

-- Returns the smallIDs whose relations changed.
local function applyRelations(self: ClientState, relations: { any }): { number }
	local changed = {}
	for _, r in relations do
		local p = self.players[r.smallID]
		if p then
			p.allies = r.allies
			p.embargoes = r.embargoes
			p.traitor = r.traitor == true
			p.disconnected = r.disconnected == true
			p.allyExpiry = r.allyExpiry or {}
			p.betrayals = r.betrayals or 0
			p.traitorUntil = r.traitorUntil
			table.insert(changed, r.smallID)
		end
	end
	return changed
end

local function diplomacySignature(d: Diplomacy): string
	local parts = {}
	for _, a in d.alliances do
		table.insert(parts, `a{a.id}:{a.other}:{a.expiresAt}:{a.extensionRequested}`)
	end
	for _, r in d.incoming do
		table.insert(parts, `i{r.requestor}:{r.createdAt}`)
	end
	for _, r in d.outgoing do
		table.insert(parts, `o{r.recipient}:{r.createdAt}`)
	end
	return table.concat(parts, ",")
end

-- Name anchors arrive as the ones that changed (packed rows) and the ids
-- that went; `self.names` is replaced by a new table each time.
local function applyNames(self: ClientState, names: buffer?, gone: { number }?, replace: boolean)
	local out: { [number]: NameAnchor } = if replace then {} else table.clone(self.names)
	if names then
		for _, n in Replication.decodeNames(names) do
			out[n.smallID] = { x = n.x, y = n.y, size = n.size }
		end
	end
	if gone then
		for _, id in gone do
			out[id] = nil
		end
	end
	self.names = out
end

-- A motion plan as it arrived, with its packed path unpacked.
local function unpackPlans(records: { any }): { any }
	local out = table.create(#records)
	for i, record in records do
		if type(record.path) == "buffer" then
			record = table.clone(record)
			record.path = Replication.unpackPath(record.path)
		end
		out[i] = record
	end
	return out
end

local function applyStats(self: ClientState, packed: buffer)
	for _, s in Replication.decodeStats(packed) do
		local p = self.players[s.smallID]
		if p then
			p.tiles = s.tiles
			p.troops = s.troops
			p.maxTroops = s.maxTroops or p.maxTroops
			p.gold = s.gold or p.gold
			p.alive = s.alive
			p.spawnTile = s.spawnTile
		end
	end
end

-- A snapshot of the match already on screen: the viewer now commands another
-- nation (the Arsenal's Takeover). Only who "you" are and what the viewer may
-- see changes; the map, units, plans and railroads are the same match's and
-- carry on from the deltas, so nothing is rebuilt (Bruno, 2026-11-12: the
-- takeover's full reload was slow, and once never finished). Fires the
-- signals for what changed, then Rebound.
local function rebind(self: ClientState, snap: { [string]: any })
	self.winner = snap.winner
	self.you = snap.you
	self.gold = snap.gold or 0
	self.players = {}
	self.rosterOrder = {}
	local roster = addRoster(self, snap.roster)
	applyStats(self, snap.stats)
	local related = applyRelations(self, snap.relations or {})
	applyNames(self, snap.names, nil, true)
	self.attacks = snap.attacks or {}
	self.diplomacy = snap.diplomacy or { alliances = {}, incoming = {}, outgoing = {} }
	self.costs = snap.costs or {}
	self.arsenal = snap.arsenal
	self.RosterChanged:Fire(roster)
	self.StatsChanged:Fire()
	self.RelationsChanged:Fire(related)
	self.NamesChanged:Fire()
	self.AttacksChanged:Fire()
	self.DiplomacyChanged:Fire()
	self.Rebound:Fire()
end

-- `inPlace`: the caller still shows this match (its map is up), so a
-- snapshot of the same match rebinds rather than starting over.
function ClientState.applySnapshot(self: ClientState, snap: { [string]: any }, inPlace: boolean?)
	assert(snap.v == Replication.VERSION, "unsupported snapshot version")
	if inPlace and self.ready and snap.gameID ~= nil and snap.gameID == self.gameID then
		rebind(self, snap)
		return
	end
	self.gameID = snap.gameID
	self.tick = snap.tick
	self.mapName = snap.mapName
	self.mapFolder = snap.mapFolder
	self.mapSize = snap.mapSize
	self.gameConfig = snap.gameConfig or {}
	self._config = nil
	self.paused = snap.paused == true
	self.width = snap.width
	self.height = snap.height
	self.startTick = snap.startTick
	self.deployDeadline = snap.deployDeadline
	self.winner = snap.winner
	self.landTotal = snap.landTotal or 0
	self.you = snap.you
	self.gold = snap.gold or 0
	self.tileState = buffer.create(snap.width * snap.height * 2)
	Replication.decodeTileStates(snap.tileState, self.tileState)
	self.players = {}
	self.rosterOrder = {}
	addRoster(self, snap.roster)
	applyStats(self, snap.stats)
	self.units = {}
	for _, u in snap.units do
		self.units[u.id] = u
	end
	self.plans = MotionPlanResolver.new()
	self.plans:applyRecords(unpackPlans(snap.plans or {}))
	self:_advancePlans()
	self.railroads = {}
	for _, r in snap.railroads or {} do
		self.railroads[r.id] = r.tiles
	end
	self.attacks = snap.attacks or {}
	applyRelations(self, snap.relations or {})
	applyNames(self, snap.names, nil, true)
	self.diplomacy = snap.diplomacy or { alliances = {}, incoming = {}, outgoing = {} }
	self.costs = snap.costs or {}
	-- Conquest's Arsenal (private): { weapons, reinforceReadyAt } or nil.
	self.arsenal = snap.arsenal
	self.ready = true
	self.Snapshot:Fire()
end

function ClientState.applyDelta(self: ClientState, delta: { [string]: any })
	if not self.ready then
		return
	end
	self.tick = delta.tick
	local changed = Replication.decodeTileChanges(delta.tiles, self.tileState)
	if #changed > 0 then
		self.TilesChanged:Fire(changed)
	end
	if delta.roster and #delta.roster > 0 then
		self.RosterChanged:Fire(addRoster(self, delta.roster))
	end
	-- Everyone's stats (when sent), then the viewer's own row (every tick).
	if delta.stats or delta.me then
		if delta.stats then
			applyStats(self, delta.stats)
		end
		if delta.me then
			applyStats(self, delta.me)
		end
		self.StatsChanged:Fire()
	end
	if delta.gold ~= nil and delta.gold ~= self.gold then
		self.gold = delta.gold
		self.StatsChanged:Fire()
	end
	if delta.arsenal ~= nil then
		self.arsenal = delta.arsenal
	end
	if delta.costs ~= nil then
		self.costs = delta.costs
	end
	if (delta.units and #delta.units > 0) or (delta.removed and #delta.removed > 0) then
		-- A full record (it has a type) or a patch on the record we hold;
		-- either way the unit gets a new record table.
		local records = table.create(#delta.units)
		for _, u in delta.units do
			if u.type ~= nil then
				self.units[u.id] = u
				table.insert(records, u)
			else
				local old = self.units[u.id]
				if old ~= nil then
					local new = table.clone(old)
					for key, value in u do
						new[key] = value
					end
					new.clear = nil
					for _, key in u.clear or {} do
						new[key] = nil
					end
					-- It moved without saying from where: from where it was.
					if u.tile ~= nil and u.lastTile == nil then
						new.lastTile = old.tile
					end
					self.units[u.id] = new
					table.insert(records, new)
				end
			end
		end
		for _, id in delta.removed do
			self.units[id] = nil
			self.plans:unitRemoved(id)
		end
		self.UnitsChanged:Fire(records, delta.removed)
	end
	if delta.plans and #delta.plans > 0 then
		local plans = unpackPlans(delta.plans)
		self.plans:applyRecords(plans)
		self.PlansArrived:Fire(plans)
	end
	local moved = self:_advancePlans()
	if #moved > 0 then
		self.UnitsMoved:Fire(moved)
	end
	if delta.events then
		self:_applyEvents(delta.events)
	end
	if delta.attacks then
		self.attacks = delta.attacks
		self.AttacksChanged:Fire()
	end
	if delta.relations then
		self.RelationsChanged:Fire(applyRelations(self, delta.relations))
	end
	if delta.names or delta.namesGone then
		applyNames(self, delta.names, delta.namesGone, false)
		self.NamesChanged:Fire()
	end
	if delta.diplomacy then
		local old, new = self.diplomacy, delta.diplomacy
		self.diplomacy = new
		if diplomacySignature(old) ~= diplomacySignature(new) then
			self.DiplomacyChanged:Fire()
		end
	end
	if delta.landTotal ~= nil then
		self.landTotal = delta.landTotal
	end
	if delta.deployDeadline ~= nil then
		self.deployDeadline = delta.deployDeadline
	end
	if delta.startTick ~= nil or delta.winner ~= nil then
		if delta.startTick ~= nil then
			self.startTick = delta.startTick
		end
		if delta.winner ~= nil then
			self.winner = delta.winner
		end
		self.PhaseChanged:Fire()
	end
	if delta.messages then
		self.Messages:Fire(delta.messages)
	end
	self.TickApplied:Fire(self.tick)
end

-- Plan-driven units (boats, trade ships, nukes, trains) take their tile for
-- this tick from their motion plan; returns the ids that moved.
function ClientState._advancePlans(self: ClientState): { number }
	local moved = {}
	local units = self.units
	self.plans:advance(self.tick, {
		tileOf = function(id: number): number?
			local u = units[id]
			return if u and u.active ~= false then u.tile else nil
		end,
		move = function(id: number, tile: number)
			local u = units[id]
			u.lastTile = u.tile
			u.tile = tile
			table.insert(moved, id)
		end,
		rest = function(_id: number) end,
	})
	return moved
end

function ClientState._applyEvents(self: ClientState, events: { any })
	local added, removed, bonuses, diplomacy = {}, {}, {}, {}
	for _, e in events do
		if e.type == "RailroadConstructionEvent" then
			self.railroads[e.id] = e.tiles
			table.insert(added, e.id)
		elseif e.type == "RailroadDestructionEvent" then
			self.railroads[e.id] = nil
			table.insert(removed, e.id)
		elseif e.type == "RailroadSnapEvent" then
			self.railroads[e.originalId] = nil
			table.insert(removed, e.originalId)
			self.railroads[e.newId1] = e.tiles1
			self.railroads[e.newId2] = e.tiles2
			table.insert(added, e.newId1)
			table.insert(added, e.newId2)
		elseif e.type == "BonusEvent" then
			table.insert(bonuses, e)
		elseif e.type == "GamePaused" then
			self.paused = e.paused
			self.PhaseChanged:Fire()
		else
			table.insert(diplomacy, e)
		end
	end
	if #added > 0 or #removed > 0 then
		self.RailroadsChanged:Fire(added, removed)
	end
	if #bonuses > 0 then
		self.Bonus:Fire(bonuses)
	end
	if #diplomacy > 0 then
		self.DiplomacyEvents:Fire(diplomacy)
	end
end

-- Queries ---------------------------------------------------------------------

-- The match's EngineConfig (static rules: durations, ranges, radii).
function ClientState.config(self: ClientState): any
	if self._config == nil then
		self._config = EngineConfig.new(self.gameConfig :: any, false)
	end
	return self._config
end

function ClientState.ownerAt(self: ClientState, tile: number): number
	return bit32.band(buffer.readu16(self.tileState, tile * 2), 0xfff)
end

function ClientState.player(self: ClientState, smallID: number): PlayerView?
	return self.players[smallID]
end

function ClientState.me(self: ClientState): PlayerView?
	return self.players[self.you]
end

function ClientState.inSpawnPhase(self: ClientState): boolean
	return self.startTick == nil
end

return ClientState
