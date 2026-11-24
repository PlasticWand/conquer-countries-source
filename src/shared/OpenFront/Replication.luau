--!strict
-- Server-to-client state for the OpenFront port (docs/openfront-port/RENDER_CONTRACT.md).
-- OpenFront itself is lockstep and sends only intents. Here the server owns
-- the game and sends what each client draws:
--   - a snapshot on join
--   - one delta per tick
-- Public: tile states, the roster, every player's tiles, troops and gold
-- (OpenFront's leaderboard shows everyone's gold), units and motion plans.
-- Private to the viewer: their gold, attacks, build costs, diplomacy, event
-- messages and the diplomacy events about them (eventsFor).
--   - Tile states travel as u16 values (owner bits 0..11, fallout 13,
--     defence 14): RLE runs in snapshots, runs per state value with varint
--     tile gaps in deltas.
--   - Pure module; the server adapter sends the tables over remotes.
-- Wire format 2 (2026-11 audit: a World match sent each player 440 KB/s,
-- 402 of it stats tables). What clients end up with is unchanged; only how
-- it travels:
--   - stats: packed rows in a buffer (STAT_ROW bytes each). A viewer's own
--     row comes every tick (`me`); everyone else's STATS_EVERY ticks apart,
--     or at once when `alive` or the capital changes.
--   - units: a full record the first time a unit is sent; after that a
--     patch (`id` plus only the fields that changed, `clear` for fields now
--     nil; no `type`). A patch with `tile` and no `lastTile` means the unit
--     moved from the tile the client has.
--   - plans: `path` is a packed buffer (packPath).
--   - names: only anchors that changed (packed rows) and `namesGone`.
--   - costs, arsenal and diplomacy: only when they changed for that viewer.
-- A snapshot must be taken after collect (never between a step and its
-- collect), because patches build on what was last sent.

local ArsenalUnits = require(script.Parent.ArsenalUnits)
local Config = require(script.Parent.Config)
local LauncherExecution = require(script.Parent.Executions.LauncherExecution)
local GameTypes = require(script.Parent.GameTypes)

local Replication = {}
Replication.VERSION = 2
-- Other players' stats are sent this many ticks apart (the leaderboard
-- refreshes once a second and name labels every half second).
Replication.STATS_EVERY = 5

local Replicator = {}
Replicator.__index = Replicator

type StatRow = { tiles: number, troops: number, alive: boolean, spawn: number?, maxTroops: number, gold: number }

export type Replicator = typeof(setmetatable(
	{} :: {
		runner: any,
		rosterSent: number,
		rosterSigs: { [number]: string },
		collects: number,
		lastStats: { [number]: StatRow },
		lastUnits: { [number]: { [string]: any } },
		liveUnits: { [number]: any },
		constructionStart: { [number]: number },
		lastRelations: { [number]: string },
		lastNames: { [number]: { x: number, y: number, size: number } },
		activePlans: { [number]: any },
		packedPlans: { [any]: any },
		viewers: { [string]: { costs: string?, arsenal: string?, diplomacy: string? } },
		lastPhase: string,
		lastDeployDeadline: number?,
		lastWinner: any,
		lastLandTotal: number,
	},
	Replicator
))

function Replication.newReplicator(runner: any): Replicator
	return setmetatable({
		runner = runner,
		rosterSent = 0,
		rosterSigs = {},
		collects = 0,
		lastStats = {},
		lastUnits = {},
		liveUnits = {},
		constructionStart = {},
		lastRelations = {},
		lastNames = {},
		activePlans = {},
		packedPlans = setmetatable({}, { __mode = "k" }) :: any,
		viewers = {},
		lastPhase = "",
		lastDeployDeadline = nil,
		lastWinner = nil,
		lastLandTotal = -1,
	}, Replicator)
end

local function rosterEntry(p: any): { [string]: any }
	local info = p:info()
	return {
		smallID = p:smallID(),
		id = p:id(),
		name = p:name(),
		displayName = p:displayName(),
		type = p:type(),
		team = p:team(),
		-- A nation's country code ("us"), or a human's equipped flag id
		-- ("f_us", "o_comet_trail"; Conquest's store); `skin` is their
		-- territory skin id (Store/Skins), if any.
		flag = info.nationFlag or info.flag,
		skin = info.skin,
		-- A human's Campaign Pass cosmetics (2026-11-23; Catalog.EXTRAS ids):
		-- a title under the name, the name's style, the conquest flash and
		-- the nuke blast others see.
		title = info.title,
		nameStyle = info.nameStyle,
		conquestFx = info.conquestFx,
		blastFx = info.blastFx,
		-- Conquest: a human's Roblox user id (the server keys humans by it),
		-- for the head shot beside their name (RoWorld's labels, 2026-11-03).
		-- Bots and nations have none.
		userId = if p:type() == "HUMAN" then tonumber(p:clientID()) else nil,
	}
end

-- What a roster entry shows, as one string: a player whose entry changes
-- (a Takeover: a nation becomes a human, with their name, flag, skin and
-- user id; the human it replaced loses theirs) is sent again.
local function rosterSig(e: { [string]: any }): string
	return `{e.id}|{e.name}|{e.displayName}|{e.type}|{e.team}|{e.flag}|{e.skin}|{e.userId}|{e.title}|{e.nameStyle}|{e.conquestFx}|{e.blastFx}`
end

-- Units whose movement clients derive from motion plans: their records are
-- not resent just because they moved (OpenFront's plan-driven units).
local PLAN_DRIVEN: { [string]: true } = {
	["Transport"] = true,
	["Trade Ship"] = true,
	["Atom Bomb"] = true,
	["Hydrogen Bomb"] = true,
	["MIRV"] = true,
	["MIRV Warhead"] = true,
	["Train"] = true,
	["Mega Nuke"] = true, -- Conquest's Arsenal: flies like the Atom Bomb
	["Scattershot"] = true, -- as above (ARSENAL_V2)
}

-- UnitImpl.ts toUpdate, minus nuke trajectories (clients use motion plans).
local function unitRecord(u: any): { [string]: any }
	local lastOwner = u:lastOwner()
	local target = u:targetUnit()
	local rec: { [string]: any } = {
		id = u:id(),
		type = u:type(),
		owner = u:owner():smallID(),
		lastOwner = if lastOwner then lastOwner:smallID() else nil,
		tile = u:tile(),
		lastTile = u:lastTile(),
		troops = u:troops(),
		level = u:level(),
		underConstruction = u:isUnderConstruction(),
		active = u:isActive(),
		reachedTarget = u:reachedTarget(),
		targetTile = u:targetTile(),
		targetUnitId = if target then target:id() else nil,
		health = if u:hasHealth() then u:health() else nil,
		maxHealth = if u:hasHealth() then u:maxHealth() else nil,
		markedForDeletion = u:markedForDeletion(),
		targetable = u:isTargetable(),
		missileTimerQueue = if #u:missileTimerQueue() > 0 then table.clone(u:missileTimerQueue()) else nil,
		hasTrainStation = u:hasTrainStation(),
		trainType = u:trainType(),
		loaded = u:isLoaded(),
	}
	if u._transportShipState ~= nil then
		rec.retreating = u._transportShipState.isRetreating
	end
	-- A launcher's reload in ticks with its owner's Rapid Reload (ARSENAL_V2),
	-- so the client's reload bars run at the right pace.
	local t = u:type()
	if t == "Missile Silo" or t == "SAM Launcher" or t == "Airfield" or t == "Railgun" then
		local owner = u:owner()
		local config = u.mg:config()
		local base = if t == "Missile Silo" then config:SiloCooldown() elseif t == "SAM Launcher" then config:SAMCooldown() else LauncherExecution.RELOAD[t]
		rec.reloadTicks = Config.rapidReload(owner, base)
	end
	-- An Artillery shell's battery tile, live and final (ARSENAL_V2).
	if u._sourceTile ~= nil then
		rec.sourceTile = u._sourceTile
	end
	if u._warshipState ~= nil then
		local w = u:warshipState()
		rec.warship = {
			state = w.state,
			patrolTile = w.patrolTile,
			retreatPort = w.retreatPort,
			inCombat = w.isInCombat,
			veterancy = w.veterancy,
		}
	end
	if u._nukeState ~= nil then
		rec.waitTicks = u:nukeState().waitTicks
	end
	-- Field Works (ARSENAL_V2): the tick they go.
	if u._expiresAt ~= nil then
		rec.expiresAt = u._expiresAt
	end
	-- A sabotaged building (ARSENAL_V2), while it's dark.
	if u:isDark() then
		rec.dark = true
	end
	-- A Paratroopers plane's killer (ARSENAL_V2), so the client tells a SAM
	-- kill from its owner's cleanup.
	if t == "Paratroopers" then
		local by = u:destroyer()
		if by ~= nil and by.smallID ~= nil then
			rec.destroyer = by:smallID()
		end
	end
	local sam = u:samLauncherState()
	if sam ~= nil and sam.upgradeStartTick ~= nil then
		rec.samUpgrade = { startTick = sam.upgradeStartTick, startRange = sam.startRange, targetLevel = sam.targetLevel, duration = sam.duration }
	end
	return rec
end

-- The fields whose change makes a unit worth sending again (its position
-- too, unless a motion plan moves it).
local WATCHED = {
	"owner",
	"troops",
	"level",
	"underConstruction",
	"active",
	"reachedTarget",
	"targetTile",
	"targetUnitId",
	"health",
	"maxHealth",
	"markedForDeletion",
	"targetable",
	"hasTrainStation",
	"loaded",
	"retreating",
	"waitTicks",
	"destroyer",
	"dark",
}

local function sameList(a: { any }?, b: { any }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	if #a ~= #b then
		return false
	end
	for i, v in a do
		if b[i] ~= v then
			return false
		end
	end
	return true
end

-- One level deep: the records' sub-tables hold plain values.
local function sameTable(a: { [any]: any }, b: { [any]: any }): boolean
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function unitChanged(last: { [string]: any }, rec: { [string]: any }): boolean
	for _, key in WATCHED do
		if last[key] ~= rec[key] then
			return true
		end
	end
	if not PLAN_DRIVEN[rec.type] and last.tile ~= rec.tile then
		return true
	end
	if not sameList(last.missileTimerQueue, rec.missileTimerQueue) then
		return true
	end
	local a, b = last.warship, rec.warship
	if (a == nil) ~= (b == nil) or (a ~= nil and not sameTable(a, b)) then
		return true
	end
	local s, t = last.samUpgrade, rec.samUpgrade
	return (if s then s.startTick else nil) ~= (if t then t.startTick else nil)
end

-- What turns the record the client has (`last`) into `rec`.
local function unitPatch(last: { [string]: any }, rec: { [string]: any }): { [string]: any }
	local patch: { [string]: any } = { id = rec.id }
	for key, value in rec do
		local old = last[key]
		if old ~= value and not (type(value) == "table" and type(old) == "table" and sameTable(old, value)) then
			patch[key] = value
		end
	end
	local clear = nil
	for key in last do
		if rec[key] == nil then
			clear = clear or {}
			table.insert(clear, key)
		end
	end
	patch.clear = clear
	if PLAN_DRIVEN[rec.type] then
		-- The client moved it along its plan since: say where it is.
		patch.tile, patch.lastTile = rec.tile, rec.lastTile
	elseif patch.tile ~= nil then
		-- The usual step: it came from the tile the client has.
		patch.lastTile = if rec.lastTile == last.tile then nil else rec.lastTile
	end
	return patch
end

-- Tile paths (motion plans): a varint count, then zigzag varint steps from
-- 0. A step to a neighbour takes 1 or 2 bytes.
function Replication.packPath(path: { number }): buffer
	local scratch = buffer.create((#path + 1) * 5)
	local o = 0
	local function varint(n: number)
		while n >= 128 do
			buffer.writeu8(scratch, o, n % 128 + 128)
			o += 1
			n //= 128
		end
		buffer.writeu8(scratch, o, n)
		o += 1
	end
	varint(#path)
	local prev = 0
	for _, tile in path do
		local d = tile - prev
		varint(if d >= 0 then d * 2 else -d * 2 - 1)
		prev = tile
	end
	local out = buffer.create(o)
	buffer.copy(out, 0, scratch, 0, o)
	return out
end

function Replication.unpackPath(data: buffer): { number }
	local o = 0
	local function varint(): number
		local n, shift = 0, 1
		while true do
			local b = buffer.readu8(data, o)
			o += 1
			n += (b % 128) * shift
			if b < 128 then
				return n
			end
			shift *= 128
		end
	end
	local count = varint()
	local path = table.create(count)
	local tile = 0
	for i = 1, count do
		local z = varint()
		tile += if z % 2 == 0 then z // 2 else -(z + 1) // 2
		path[i] = tile
	end
	return path
end

-- Stats rows: u16 smallID, u8 flags (1 alive, 2 has a capital), u32 tiles,
-- u32 capital tile, f64 troops, f64 gold, f64 maxTroops.
local STAT_ROW = 35
Replication.STAT_ROW = STAT_ROW

local function writeStat(b: buffer, o: number, id: number, row: StatRow)
	buffer.writeu16(b, o, id)
	buffer.writeu8(b, o + 2, (if row.alive then 1 else 0) + (if row.spawn ~= nil then 2 else 0))
	buffer.writeu32(b, o + 3, row.tiles)
	buffer.writeu32(b, o + 7, row.spawn or 0)
	buffer.writef64(b, o + 11, row.troops)
	buffer.writef64(b, o + 19, row.gold)
	buffer.writef64(b, o + 27, row.maxTroops)
end

-- The rows as the tables ClientState applies.
function Replication.decodeStats(data: buffer): { { smallID: number, tiles: number, troops: number, alive: boolean, spawnTile: number?, maxTroops: number, gold: number } }
	local rows = table.create(buffer.len(data) // STAT_ROW)
	for o = 0, buffer.len(data) - STAT_ROW, STAT_ROW do
		local flags = buffer.readu8(data, o + 2)
		table.insert(rows, {
			smallID = buffer.readu16(data, o),
			alive = flags % 2 == 1,
			spawnTile = if flags >= 2 then buffer.readu32(data, o + 7) else nil,
			tiles = buffer.readu32(data, o + 3),
			troops = buffer.readf64(data, o + 11),
			gold = buffer.readf64(data, o + 19),
			maxTroops = buffer.readf64(data, o + 27),
		})
	end
	return rows
end

-- Name anchors: u16 smallID, f64 x, f64 y, f64 size.
local NAME_ROW = 26

function Replication.decodeNames(data: buffer): { { smallID: number, x: number, y: number, size: number } }
	local rows = table.create(buffer.len(data) // NAME_ROW)
	for o = 0, buffer.len(data) - NAME_ROW, NAME_ROW do
		table.insert(rows, { smallID = buffer.readu16(data, o), x = buffer.readf64(data, o + 2), y = buffer.readf64(data, o + 10), size = buffer.readf64(data, o + 18) })
	end
	return rows
end

local function encodeNames(rows: { { smallID: number, x: number, y: number, size: number } }): buffer
	local out = buffer.create(#rows * NAME_ROW)
	for i, n in rows do
		local o = (i - 1) * NAME_ROW
		buffer.writeu16(out, o, n.smallID)
		buffer.writef64(out, o + 2, n.x)
		buffer.writef64(out, o + 10, n.y)
		buffer.writef64(out, o + 18, n.size)
	end
	return out
end
Replication.encodeNames = encodeNames

-- Update types clients need: rails to draw, gold popups and diplomacy. Every
-- OpenFront client runs the whole game, and its HUD shows each player only
-- the diplomacy about them; here the server keeps the rest back (eventsFor).
local EVENT_TYPES: { [string]: true } = {
	AllianceExpired = true,
	AllianceExtension = true,
	AllianceRequest = true,
	AllianceRequestReply = true,
	BrokeAlliance = true,
	DisplayChatEvent = true,
	DonateEvent = true,
	EmbargoEvent = true,
	Emoji = true,
	GamePaused = true,
	TargetPlayer = true,
	BonusEvent = true,
	-- The conquest flag and its gold (FxSpritePass), for the conqueror only.
	ConquestEvent = true,
	-- A gold conquest's public mark (no gold), for every viewer.
	ConquestCosmeticEvent = true,
	RailroadConstructionEvent = true,
	RailroadDestructionEvent = true,
	RailroadSnapEvent = true,
}

-- Every railroad now on the map, for snapshots.
local function allRailroads(game: any): { { id: number, tiles: { number } } }
	local any = game :: any
	if any._railNetwork == nil then
		return {}
	end
	local out, seen = {}, {}
	for _, station in any._railNetwork:stationManager():getAll().list do
		for _, r in station:getRailroads().list do
			if not seen[r] then
				seen[r] = true
				table.insert(out, { id = r.id, tiles = r.tiles })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

local function statsOf(p: any): StatRow
	return { tiles = p:numTilesOwned(), troops = p:troops(), alive = p:isAlive(), spawn = p:spawnTile(), maxTroops = p.mg:config():maxTroops(p), gold = p:gold() }
end

local function sameStats(a: StatRow, b: StatRow): boolean
	return a.tiles == b.tiles and a.troops == b.troops and a.alive == b.alive and a.spawn == b.spawn and a.maxTroops == b.maxTroops and a.gold == b.gold
end

-- Attacks the viewer is part of (outgoing and incoming), for fronts and chips.
-- A player's public relations (PlayerUpdate allies and embargoes), as
-- smallIDs in the player's own order.
local function relationsOf(game: any, p: any): { [string]: any }
	local allies, embargoes, allyExpiry = {}, {}, {}
	for _, a in p:allies() do
		table.insert(allies, a:smallID())
		local alliance = p:allianceWith(a)
		table.insert(allyExpiry, if alliance then alliance:expiresAt() else 0)
	end
	for _, id in p.embargoOrder do
		local other = game:player(id)
		if other then
			table.insert(embargoes, other:smallID())
		end
	end
	return {
		smallID = p:smallID(),
		allies = allies,
		embargoes = embargoes,
		traitor = p:isTraitor(),
		disconnected = p:isDisconnected(),
		-- PlayerPanel also shows these for anyone: each ally's expiry (as
		-- allyExpiry[i] for allies[i]), betrayals and when traitor ends (an
		-- absolute tick, so the record doesn't change every tick).
		allyExpiry = allyExpiry,
		betrayals = p:betrayals(),
		traitorUntil = if p:isTraitor() then game:ticks() + p:getTraitorRemainingTicks() else nil,
	}
end

-- What each build-bar item costs the viewer now (UnitDisplay's prices; the
-- engine's cost depends on what they built and on MIRVs launched).
local BUILD_BAR = {
	"City",
	"Factory",
	"Port",
	"Defense Post",
	"Missile Silo",
	"SAM Launcher",
	"Warship",
	"Atom Bomb",
	"Hydrogen Bomb",
	"MIRV",
}
Replication.BUILD_BAR = BUILD_BAR

local function costsFor(player: any): { [string]: number }
	local game = player.mg
	local out = {}
	for _, t in BUILD_BAR do
		out[t] = game:unitInfo(t).cost(game, player)
	end
	-- Conquest's Arsenal: each unlocked weapon's price.
	for _, e in ArsenalUnits.BUILD do
		if player:hasExtraWeapon(e.key) then
			out[e.type] = game:unitInfo(e.type).cost(game, player)
		end
	end
	return out
end

-- Conquest's Arsenal, private to the viewer: what they unlocked (when the
-- match has extra weapons on) and when Reinforcements are ready again.
local function arsenalFor(player: any): { [string]: any }?
	local game = player.mg
	if not game:config():extraWeapons() then
		return nil
	end
	local weapons = {}
	for _, key in ArsenalUnits.KEYS do
		if player:hasExtraWeapon(key) then
			weapons[key] = true
		end
	end
	-- Eliminated by an AI nation: whom a Takeover would put them in command of.
	local takeover = nil
	local by = if not player:isAlive() then player._conqueredBy else nil
	if by ~= nil and by:isPlayer() and by:type() == "NATION" and by:isAlive() and by:numTilesOwned() > 0 then
		takeover = { smallID = by:smallID(), name = by:displayName() }
	end
	return { weapons = weapons, reinforceReadyAt = player.reinforceReadyAt or 0, paraReadyAt = player.paraReadyAt or 0, sabotageReadyAt = player.sabotageReadyAt or 0, fieldWorksReadyAt = player.fieldWorksReadyAt or 0, takeover = takeover }
end

-- The viewer's own alliances (PlayerUpdate AllianceView) and pending
-- requests, for the alliance prompts.
local function diplomacyFor(player: any): { [string]: any }
	local alliances, incoming, outgoing = {}, {}, {}
	for _, a in player:alliances() do
		table.insert(alliances, {
			id = a:id(),
			other = a:other(player):smallID(),
			createdAt = a:createdAt(),
			expiresAt = a:expiresAt(),
			extensionRequested = a:agreedToExtend(player),
		})
	end
	for _, r in player:incomingAllianceRequests() do
		table.insert(incoming, { requestor = r:requestor():smallID(), createdAt = r:createdAt() })
	end
	for _, r in player:outgoingAllianceRequests() do
		table.insert(outgoing, { recipient = r:recipient():smallID(), createdAt = r:createdAt() })
	end
	return { alliances = alliances, incoming = incoming, outgoing = outgoing }
end

-- GameRunner's playerNameViewData, by smallID.
local function nameAnchors(game: any, runner: any): { { smallID: number, x: number, y: number, size: number } }
	local out = {}
	for id, a in runner.names.anchors do
		local p = game:player(id)
		if p then
			table.insert(out, { smallID = p:smallID(), x = a.x, y = a.y, size = a.size })
		end
	end
	return out
end

-- Signatures of a viewer's private parts, to send them only when they change.
local function costsSignature(costs: { [string]: number }): string
	local parts = {}
	for _, t in BUILD_BAR do
		table.insert(parts, tostring(costs[t]))
	end
	for _, e in ArsenalUnits.BUILD do
		table.insert(parts, tostring(costs[e.type]))
	end
	return table.concat(parts, ",")
end

local function arsenalSignature(a: { [string]: any }?): string
	if a == nil then
		return ""
	end
	local parts = {}
	for _, key in ArsenalUnits.KEYS do
		table.insert(parts, if a.weapons[key] then "1" else "0")
	end
	local t = a.takeover
	return `{table.concat(parts)}|{a.reinforceReadyAt}|{a.paraReadyAt}|{a.sabotageReadyAt}|{a.fieldWorksReadyAt}|{if t then t.smallID else ""}|{if t then t.name else ""}`
end

local function diplomacySignature(d: { [string]: any }): string
	local parts = {}
	for _, a in d.alliances do
		table.insert(parts, `a{a.id}:{a.other}:{a.createdAt}:{a.expiresAt}:{a.extensionRequested}`)
	end
	for _, r in d.incoming do
		table.insert(parts, `i{r.requestor}:{r.createdAt}`)
	end
	for _, r in d.outgoing do
		table.insert(parts, `o{r.recipient}:{r.createdAt}`)
	end
	return table.concat(parts, ",")
end

local function attacksFor(player: any): { { [string]: any } }
	local out = {}
	for _, a in player:outgoingAttacks() do
		local target = a:target()
		table.insert(out, {
			id = a:id(),
			attacker = player:smallID(),
			target = target:smallID(),
			troops = a:troops(),
			retreating = a:retreating(),
			outgoing = true,
		})
	end
	for _, a in player:incomingAttacks() do
		table.insert(out, {
			id = a:id(),
			attacker = a:attacker():smallID(),
			target = player:smallID(),
			troops = a:troops(),
			retreating = a:retreating(),
			outgoing = false,
		})
	end
	return out
end

-- RLE of the u16 tile states: (u16 value, u32 run) pairs.
local function encodeTileStates(map: any): buffer
	local n = map:width() * map:height()
	local runs = {}
	local i = 0
	while i < n do
		local v = map:tileState(i)
		local j = i + 1
		while j < n and map:tileState(j) == v do
			j += 1
		end
		table.insert(runs, v)
		table.insert(runs, j - i)
		i = j
	end
	local out = buffer.create(#runs // 2 * 6)
	for k = 1, #runs, 2 do
		local o = (k - 1) // 2 * 6
		buffer.writeu16(out, o, runs[k])
		buffer.writeu32(out, o + 2, runs[k + 1])
	end
	return out
end

function Replication.decodeTileStates(data: buffer, into: buffer)
	local o, t = 0, 0
	local len = buffer.len(data)
	while o < len do
		local v = buffer.readu16(data, o)
		local run = buffer.readu32(data, o + 2)
		for k = 0, run - 1 do
			buffer.writeu16(into, (t + k) * 2, v)
		end
		t += run
		o += 6
	end
end

-- Changed tiles as runs per state value: (u16 state, varint count, then
-- varint gaps between ascending tile indices). About 1.5-2 bytes a tile.
function Replication.encodeTileChanges(map: any, changed: { number }): buffer
	local byState: { [number]: { number } } = {}
	local states = {}
	for _, tile in changed do
		local v = map:tileState(tile)
		local list = byState[v]
		if list == nil then
			list = {}
			byState[v] = list
			table.insert(states, v)
		end
		table.insert(list, tile)
	end
	local bytes = {}
	local function varint(n: number)
		while n >= 128 do
			table.insert(bytes, n % 128 + 128)
			n //= 128
		end
		table.insert(bytes, n)
	end
	for _, v in states do
		local list = byState[v]
		table.sort(list)
		table.insert(bytes, v % 256)
		table.insert(bytes, v // 256)
		varint(#list)
		local prev = 0
		for _, tile in list do
			varint(tile - prev)
			prev = tile
		end
	end
	local out = buffer.create(#bytes)
	for i, b in bytes do
		buffer.writeu8(out, i - 1, b)
	end
	return out
end

-- Applies encodeTileChanges output to a u16 state buffer; returns the tiles.
function Replication.decodeTileChanges(data: buffer, into: buffer): { number }
	local changed = {}
	local o, len = 0, buffer.len(data)
	local function varint(): number
		local n, shift = 0, 1
		while true do
			local b = buffer.readu8(data, o)
			o += 1
			n += (b % 128) * shift
			if b < 128 then
				return n
			end
			shift *= 128
		end
	end
	while o < len do
		local v = buffer.readu16(data, o)
		o += 2
		local count = varint()
		local tile = 0
		for _ = 1, count do
			tile += varint()
			buffer.writeu16(into, tile * 2, v)
			table.insert(changed, tile)
		end
	end
	return changed
end

-- Everything a joining client needs, from the viewer's side.
function Replicator.snapshot(self: Replicator, clientID: string?): { [string]: any }
	local game = self.runner.game
	local map = game:map()
	local viewer = if clientID then game:playerByClientID(clientID) else nil
	local everyone = game:allPlayers()
	local roster = {}
	local stats = buffer.create(#everyone * STAT_ROW)
	for i, p in everyone do
		table.insert(roster, rosterEntry(p))
		writeStat(stats, (i - 1) * STAT_ROW, p:smallID(), statsOf(p))
	end
	local units = {}
	for _, u in game:units() do
		local rec = unitRecord(u)
		rec.constructionStartTick = if rec.underConstruction then self.constructionStart[rec.id] else nil
		table.insert(units, rec)
	end
	local relations = {}
	for _, p in game:allPlayers() do
		table.insert(relations, relationsOf(game, p))
	end
	local plans = {}
	for _, plan in self.activePlans do
		table.insert(plans, self:_wirePlan(plan))
	end
	-- The next delta carries this viewer's private parts again.
	if clientID then
		self.viewers[clientID] = nil
	end
	return {
		v = Replication.VERSION,
		gameID = self.runner.gameID,
		tick = game:ticks(),
		mapName = (game :: any).mapName,
		mapFolder = (game :: any).mapFolder,
		mapSize = self.runner.gameConfig.gameMapSize or "Normal",
		gameConfig = self.runner.gameConfig,
		paused = game:isPaused(),
		width = map:width(),
		height = map:height(),
		startTick = game.startTick,
		deployDeadline = (game :: any).deployDeadline,
		winner = self:_winnerId(),
		landTotal = game:totalLandTiles(),
		you = if viewer then viewer:smallID() else 0,
		gold = if viewer then viewer:gold() else nil,
		roster = roster,
		stats = stats,
		tileState = encodeTileStates(map),
		units = units,
		plans = plans,
		railroads = allRailroads(game),
		attacks = if viewer then attacksFor(viewer) else {},
		diplomacy = if viewer then diplomacyFor(viewer) else nil,
		costs = if viewer then costsFor(viewer) else nil,
		arsenal = if viewer then arsenalFor(viewer) else nil,
		relations = relations,
		names = encodeNames(nameAnchors(game, self.runner)),
	}
end

-- A motion plan as it travels: its path packed (once per plan).
function Replicator._wirePlan(self: Replicator, plan: any): any
	local wire = self.packedPlans[plan]
	if wire == nil then
		wire = table.clone(plan)
		wire.path = Replication.packPath(plan.path)
		self.packedPlans[plan] = wire
	end
	return wire
end

function Replicator._winnerId(self: Replicator): any
	local w = self.runner.game:getWinner()
	if w == nil then
		return nil
	end
	return if type(w) == "table" then w:id() else w
end

-- The public part of this tick's delta; call once per tick after the step.
function Replicator.collect(self: Replicator): { [string]: any }
	local game = self.runner.game
	local map = game:map()
	-- Tiles: the last state of each changed tile, grouped by state value
	-- (Replication.encodeTileChanges).
	local seen: { [number]: true } = {}
	local changed = {}
	for _, tile in game:drainTileUpdates() do
		if not seen[tile] then
			seen[tile] = true
			table.insert(changed, tile)
		end
	end
	local tiles = Replication.encodeTileChanges(map, changed)
	-- New players, players whose entry changed (checked on full ticks), and
	-- changed stats. `delta.roster` is "new or changed" (Codex agreed,
	-- 2026-11-12; same wire version): clients update a known entry in place.
	local all = game:allPlayers()
	local roster = {}
	local full = self.collects % Replication.STATS_EVERY == 0
	if full then
		for i = 1, math.min(self.rosterSent, #all) do
			local e = rosterEntry(all[i])
			local sig = rosterSig(e)
			if self.rosterSigs[e.smallID] ~= sig then
				self.rosterSigs[e.smallID] = sig
				table.insert(roster, e)
			end
		end
	end
	for i = self.rosterSent + 1, #all do
		local e = rosterEntry(all[i])
		self.rosterSigs[e.smallID] = rosterSig(e)
		table.insert(roster, e)
	end
	self.rosterSent = #all
	-- Stats: every changed row on a full tick; between them only a player
	-- who appeared, died or moved their capital.
	self.collects += 1
	local scratch = buffer.create(#all * STAT_ROW)
	local statBytes = 0
	for _, p in all do
		local id = p:smallID()
		local last = self.lastStats[id]
		if full or last == nil or last.alive ~= p:isAlive() or last.spawn ~= p:spawnTile() then
			local row = statsOf(p)
			if last == nil or not sameStats(last, row) then
				self.lastStats[id] = row
				writeStat(scratch, statBytes, id, row)
				statBytes += STAT_ROW
			end
		end
	end
	local stats: buffer? = nil
	if statBytes > 0 then
		stats = buffer.create(statBytes)
		buffer.copy(stats :: buffer, 0, scratch, 0, statBytes)
	end
	-- Units: changed records, and ids that are gone. A unit that's gone also
	-- sends its final record (active false, its last tile, reachedTarget),
	-- like the update UnitImpl.delete leaves, so clients can draw its end.
	local units, present = {}, {}
	for _, u in game:units() do
		local rec = unitRecord(u)
		present[rec.id] = true
		self.liveUnits[rec.id] = u
		-- When construction started, as OpenFront's client derives it: the
		-- tick it first sees the unit under construction.
		if rec.underConstruction then
			if self.constructionStart[rec.id] == nil then
				self.constructionStart[rec.id] = game:ticks()
			end
			rec.constructionStartTick = self.constructionStart[rec.id]
		else
			self.constructionStart[rec.id] = nil
		end
		local last = self.lastUnits[rec.id]
		if last == nil then
			-- (a copy: the one sent may be changed by whoever receives it)
			self.lastUnits[rec.id] = table.clone(rec)
			table.insert(units, rec)
		elseif unitChanged(last, rec) then
			self.lastUnits[rec.id] = rec
			table.insert(units, unitPatch(last, rec))
		end
	end
	local removed = {}
	for id, last in self.lastUnits do
		if not present[id] then
			table.insert(removed, id)
			table.insert(units, unitPatch(last, unitRecord(self.liveUnits[id])))
			self.lastUnits[id] = nil
			self.liveUnits[id] = nil
			self.constructionStart[id] = nil
		end
	end
	-- Motion plans: this tick's, kept per unit for late joiners' snapshots.
	local plans = {}
	for _, plan in game:drainMotionPlans() do
		self.activePlans[plan.unitId or plan.engineUnitId] = plan
		table.insert(plans, self:_wirePlan(plan))
	end
	for id in self.activePlans do
		if not present[id] then
			self.activePlans[id] = nil
		end
	end
	local events = {}
	for _, update in game.updates do
		if EVENT_TYPES[update.type] then
			table.insert(events, update)
		end
	end
	-- Relations that changed, and name anchors when GameRunner recomputed them.
	local relations = {}
	for _, p in all do
		local rel = relationsOf(game, p)
		local sig = `{table.concat(rel.allies, ",")}|{table.concat(rel.embargoes, ",")}|{rel.traitor}|{rel.disconnected}|{table.concat(rel.allyExpiry, ",")}|{rel.betrayals}|{rel.traitorUntil}`
		if self.lastRelations[rel.smallID] ~= sig then
			self.lastRelations[rel.smallID] = sig
			table.insert(relations, rel)
		end
	end
	-- Name anchors, when GameRunner recomputed them: the ones that changed
	-- and the ones that went.
	local names: buffer? = nil
	local namesGone: { number }? = nil
	if self.runner.namesChanged then
		local rows, placed = {}, {}
		for _, n in nameAnchors(game, self.runner) do
			placed[n.smallID] = true
			local last = self.lastNames[n.smallID]
			if last == nil or last.x ~= n.x or last.y ~= n.y or last.size ~= n.size then
				self.lastNames[n.smallID] = { x = n.x, y = n.y, size = n.size }
				table.insert(rows, n)
			end
		end
		local gone = {}
		for id in self.lastNames do
			if not placed[id] then
				table.insert(gone, id)
			end
		end
		for _, id in gone do
			self.lastNames[id] = nil
		end
		if #gone > 0 then
			namesGone = gone
		end
		if #rows > 0 then
			names = encodeNames(rows)
		end
	end
	local phase = if game:inSpawnPhase() then "spawn" else "playing"
	local delta: { [string]: any } = {
		tick = game:ticks(),
		tiles = tiles,
		roster = roster,
		stats = stats,
		units = units,
		removed = removed,
		plans = plans,
		events = if #events > 0 then events else nil,
		relations = if #relations > 0 then relations else nil,
		names = names,
		namesGone = namesGone,
	}
	if phase ~= self.lastPhase then
		self.lastPhase = phase
		delta.startTick = game.startTick
	end
	-- Conquest: the solo deploy countdown's end tick (DeployCountdownExecution).
	local deadline = (game :: any).deployDeadline
	if deadline ~= self.lastDeployDeadline then
		self.lastDeployDeadline = deadline
		delta.deployDeadline = deadline
	end
	-- Land without fallout: the leaderboard's share denominator (StatsColumns).
	local landTotal = game:totalLandTiles()
	if landTotal ~= self.lastLandTotal then
		self.lastLandTotal = landTotal
		delta.landTotal = landTotal
	end
	local winner = self:_winnerId()
	if winner ~= self.lastWinner then
		self.lastWinner = winner
		delta.winner = winner
	end
	return delta
end

-- Which of a tick's events a viewer may see (nil: a spectator), by the rules
-- OpenFront's HUD applies (EventsDisplay, ActionableEvents, PlayerIcons):
--   - alliance requests, replies, extensions and expiries, betrayals,
--     embargoes and donations: the two players involved
--   - quick chat: the player it is addressed to (displayChat runs once each
--     for sender and recipient)
--   - emoji: sender and recipient, or everyone for AllPlayers
--   - targets: the targeter and its friends (allies, team)
--   - the rest (gold popups, rails, pause) is public
local PRIVATE_EVENTS: { [string]: true } = {
	AllianceExpired = true,
	AllianceExtension = true,
	AllianceRequest = true,
	AllianceRequestReply = true,
	BrokeAlliance = true,
	DisplayChatEvent = true,
	DonateEvent = true,
	EmbargoEvent = true,
	Emoji = true,
	TargetPlayer = true,
	ConquestEvent = true,
}

function Replication.eventsFor(game: any, events: { any }?, viewer: any?): { any }?
	if events == nil then
		return nil
	end
	local me = if viewer then viewer:smallID() else -1
	local myId = if viewer then viewer:id() else nil
	local out = {}
	for _, e in events do
		local kind = e.type
		local show = false
		if not PRIVATE_EVENTS[kind] then
			show = true
		elseif kind == "Emoji" then
			local msg = e.emoji
			show = msg.recipientID == GameTypes.AllPlayers or msg.senderID == me or msg.recipientID == me
		elseif viewer == nil then
			show = false
		elseif kind == "AllianceRequest" then
			show = e.requestorID == me or e.recipientID == me
		elseif kind == "AllianceRequestReply" then
			show = e.request.requestorID == me or e.request.recipientID == me
		elseif kind == "BrokeAlliance" then
			show = e.traitorID == me or e.betrayedID == me
		elseif kind == "AllianceExpired" then
			show = e.player1ID == me or e.player2ID == me
		elseif kind == "AllianceExtension" then
			show = e.playerID == me
			if not show then
				for _, a in viewer:alliances() do
					if a:id() == e.allianceID then
						show = true
					end
				end
			end
		elseif kind == "DisplayChatEvent" then
			show = e.playerID == me
		elseif kind == "DonateEvent" then
			show = e.senderId == myId or e.recipientId == myId
		elseif kind == "EmbargoEvent" then
			show = e.playerID == me or e.embargoedID == me
		elseif kind == "ConquestEvent" then
			-- Its gold is private; the flag is only for your own conquests (Bruno, 2026-10-28).
			show = e.conquerorId == myId
		elseif kind == "TargetPlayer" then
			local targeter = game:playerBySmallID(e.playerID)
			show = e.playerID == me or (targeter ~= nil and targeter.isPlayer ~= nil and targeter:isPlayer() and viewer:isFriendly(targeter))
		end
		if show then
			table.insert(out, e)
		end
	end
	return if #out > 0 then out else nil
end

-- The viewer's copy: the public delta plus their gold, attacks and messages,
-- with only the events they may see. An unknown clientID (a spectator) gets
-- the public part only.
function Replicator.forViewer(self: Replicator, public: { [string]: any }, clientID: string?, messages: { any }?): { [string]: any }
	local game = self.runner.game
	local viewer = if clientID then game:playerByClientID(clientID) else nil
	local out = table.clone(public)
	out.events = Replication.eventsFor(game, public.events, viewer)
	if viewer then
		out.gold = viewer:gold()
		out.attacks = attacksFor(viewer)
		-- Their own stats every tick (everyone's come less often).
		local me = buffer.create(STAT_ROW)
		writeStat(me, 0, viewer:smallID(), statsOf(viewer))
		out.me = me
		-- Diplomacy, prices and the Arsenal only when they changed.
		local sent = self.viewers[clientID :: string]
		if sent == nil then
			sent = {}
			self.viewers[clientID :: string] = sent
		end
		local diplomacy = diplomacyFor(viewer)
		local dsig = diplomacySignature(diplomacy)
		if sent.diplomacy ~= dsig then
			sent.diplomacy = dsig
			out.diplomacy = diplomacy
		end
		local costs = costsFor(viewer)
		local csig = costsSignature(costs)
		if sent.costs ~= csig then
			sent.costs = csig
			out.costs = costs
		end
		local arsenal = arsenalFor(viewer)
		local asig = arsenalSignature(arsenal)
		if sent.arsenal ~= asig then
			sent.arsenal = asig
			out.arsenal = arsenal
		end
		if messages then
			local mine = {}
			for _, m in messages do
				if m.playerId == viewer:id() then
					table.insert(mine, m)
				end
			end
			if #mine > 0 then
				out.messages = mine
			end
		end
	end
	return out
end

return Replication
