--!strict
-- The public queues behind the main menu's "Public matches" rows
-- (docs/design/rofront-ui-pass.md, screen 1). Pure; the server drives it.
--   ffa    "Public match": OpenFront's FFA playlist (MapPlaylist), the next
--          map shown in advance
--   world  World FFA, always
--   team   OpenFront's team playlist (Duos, Quads, 5 teams, Humans vs Nations...)
-- Each queue holds the config of its next game, rolled when the lobby opens,
-- so its map and mode can be shown. The countdown starts when the first
-- player joins; at zero the server starts the game with everyone queued
-- (nations and tribes fill the map). One live game per queue: while it runs
-- the row offers Watch, and the lobby reopens when it ends.
-- Parties join and leave together (the server passes the party).

local OF = script.Parent.OpenFront
local GameTypes = require(OF.GameTypes)
local Lang = require(OF.Lang)
local MapInfo = require(OF.Data.MapInfo) :: { any }

local Lobbies = {}
Lobbies.__index = Lobbies

Lobbies.COUNTDOWN = 20 -- seconds from the first join

export type QueueId = "ffa" | "world" | "team"

export type Queue = {
	id: QueueId,
	kind: "ffa" | "team",
	forcedMap: string?,
	config: { [string]: any },
	members: { string }, -- player keys, in join order
	opensAt: number?, -- when the countdown ends
	live: { players: number, startedAt: number }?,
}

export type Row = {
	id: string,
	title: string,
	mapName: string,
	mapType: string,
	mode: string?, -- "Quads", "5 teams", "Humans vs Nations"
	players: number,
	capacity: number,
	seconds: number?, -- countdown, once someone joined
	live: boolean,
	liveSeconds: number?,
}

export type Lobbies = typeof(setmetatable(
	{} :: {
		playlist: any,
		now: () -> number,
		queues: { Queue },
		byId: { [string]: Queue },
		queueOf: { [string]: Queue },
	},
	Lobbies
))

local function mapName(mapType: string): string
	for _, m in MapInfo do
		if m.type == mapType then
			return Lang.t(m.translationKey)
		end
	end
	return mapType
end
Lobbies.mapName = mapName

function Lobbies.modeText(config: { [string]: any }): string?
	local teams = config.playerTeams
	if config.gameMode ~= "Team" or teams == nil then
		return nil
	end
	if teams == GameTypes.HumansVsNations then
		return "Humans vs Nations"
	elseif type(teams) == "number" then
		return `{teams} teams`
	end
	return tostring(teams)
end

-- `playlist` is an OpenFront MapPlaylist; `worldAvailable` turns the World queue on.
function Lobbies.new(playlist: any, now: () -> number, worldAvailable: boolean): Lobbies
	local self = setmetatable({ playlist = playlist, now = now, queues = {}, byId = {}, queueOf = {} }, Lobbies)
	local defs: { { id: QueueId, kind: "ffa" | "team", forcedMap: string? } } = { { id = "ffa", kind = "ffa" } }
	if worldAvailable then
		table.insert(defs, { id = "world", kind = "ffa", forcedMap = "World" })
	end
	table.insert(defs, { id = "team", kind = "team" })
	for _, d in defs do
		local q: Queue = { id = d.id, kind = d.kind, forcedMap = d.forcedMap, config = playlist:gameConfig(d.kind, d.forcedMap), members = {}, opensAt = nil, live = nil }
		table.insert(self.queues, q)
		self.byId[d.id] = q
	end
	return self
end

function Lobbies.queueOfPlayer(self: Lobbies, key: string): Queue?
	return self.queueOf[key]
end

-- Removes a player from whatever queue they are in. An empty lobby stops its countdown.
function Lobbies.leave(self: Lobbies, key: string)
	local q = self.queueOf[key]
	if q == nil then
		return
	end
	local i = table.find(q.members, key)
	if i then
		table.remove(q.members, i)
	end
	self.queueOf[key] = nil
	if #q.members == 0 then
		q.opensAt = nil
	end
end

-- Joins a queue with the player's party (keys in the menu). Returns false if
-- the queue is unknown, live, or too full for the whole party.
function Lobbies.join(self: Lobbies, id: string, keys: { string }): boolean
	local q = self.byId[id]
	if q == nil or q.live ~= nil then
		return false
	end
	local incoming = 0
	for _, key in keys do
		if self.queueOf[key] ~= q then
			incoming += 1
		end
	end
	if #q.members + incoming > (q.config.maxPlayers or 50) then
		return false
	end
	for _, key in keys do
		if self.queueOf[key] ~= q then
			self:leave(key)
			table.insert(q.members, key)
			self.queueOf[key] = q
		end
	end
	if q.opensAt == nil then
		q.opensAt = self.now() + Lobbies.COUNTDOWN
	end
	return true
end

-- Queues whose countdown has ended, each with its members and config. The
-- queue is now live (call ended() when its game is over); its lobby rolls
-- the next config.
function Lobbies.due(self: Lobbies): { { queue: Queue, members: { string }, config: { [string]: any } } }
	local out = {}
	local now = self.now()
	for _, q in self.queues do
		if q.opensAt and now >= q.opensAt and #q.members > 0 and q.live == nil then
			local members = q.members
			for _, key in members do
				self.queueOf[key] = nil
			end
			table.insert(out, { queue = q, members = members, config = q.config })
			q.live = { players = #members, startedAt = now }
			q.members = {}
			q.opensAt = nil
			q.config = self.playlist:gameConfig(q.kind, q.forcedMap)
		end
	end
	return out
end

-- The queue's live game ended (or failed to start); its lobby is open again.
function Lobbies.ended(self: Lobbies, id: string)
	local q = self.byId[id]
	if q then
		q.live = nil
	end
end

-- What the menu shows, one row per queue.
function Lobbies.rows(self: Lobbies): { Row }
	local now = self.now()
	local out: { Row } = {}
	for _, q in self.queues do
		local cfg = q.config
		local title = if q.id == "ffa" then "Public match" else mapName(cfg.gameMap)
		local row: Row = {
			id = q.id,
			title = title,
			mapName = mapName(cfg.gameMap),
			mapType = cfg.gameMap,
			mode = Lobbies.modeText(cfg),
			players = if q.live then q.live.players else #q.members,
			capacity = cfg.maxPlayers or 50,
			seconds = if q.opensAt then math.max(0, q.opensAt - now) else nil,
			live = q.live ~= nil,
			liveSeconds = if q.live then now - q.live.startedAt else nil,
		}
		table.insert(out, row)
	end
	return out
end

return Lobbies
