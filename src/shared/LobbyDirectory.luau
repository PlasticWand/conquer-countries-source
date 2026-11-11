--!strict
-- Ported from RoWorld 2be8efb (src/server/Lobbies/LobbyDirectory.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- The public-lobby directory on a hub server (an ordinary public server):
-- keeps the game-wide list of upcoming public matches fresh, creates new
-- ones when too few are open (one hub at a time, elected by a short store
-- lock), shows them to its players, seats joiners in the soonest lobby of the
-- kind they asked for (Quick Play) and sends them to its reserved server.
-- With every lobby of a kind full, a joiner waits in line on this hub.
-- Pure with injected dependencies, so Lune runs it:
--   deps = {
--     store = LobbyStore,
--     teleport = { reserve = () -> (code, psid), send = (players, code, data) -> (ok, err?) },
--     config = (kind) -> gameConfig,   -- the next OpenFront config of that kind (MapPlaylist)
--     now = () -> number,              -- the shared clock (seconds)
--     rand = () -> number,             -- [0, 1)
--     newId = () -> string,
--     worldAvailable = boolean,        -- World's own kind is offered
--     serverSize = (() -> number?)?,   -- most players a server holds (seats never past it)
--     uidOf = ((player) -> string)?,   -- default tostring(player.UserId)
--     wait = ((number) -> ())?,        -- pauses between store retries (task.wait live)
--     log = ((string) -> ())?,
--   }
-- Teleport data a match server receives: { lobby = id, party = { key, uids, leader }?, spectate = true? }.

local PublicLobbies = require(script.Parent.PublicLobbies)

local LobbyDirectory = {}
LobbyDirectory.__index = LobbyDirectory

LobbyDirectory.REFRESH_S = 3.0
LobbyDirectory.LOCK_TTL_S = 10
-- A hub refused the "scheduler" lock asks again only after a random wait in
-- this range, not at every refresh (RoWorld: hundreds of hubs asking every
-- refresh were a third of its store traffic).
LobbyDirectory.LOCK_RETRY_S = { 8.0, 16.0 }
-- Open lobbies whose start passed this long ago without a match server
-- marking them started had nobody join: removed.
LobbyDirectory.STALE_AFTER_S = 30
LobbyDirectory.JOIN_TRIES = 3
-- joinPublic's reason when no lobby of the kind has room now (the caller
-- puts the player in line).
LobbyDirectory.NO_ROOM = "no room"
LobbyDirectory.UNREACHABLE = "Couldn't reach the lobby list. Try again in a moment."
-- Players in line are tried again this often, this many store calls at most
-- each time, for this long at most.
LobbyDirectory.QUEUE_RETRY_S = 1.0
LobbyDirectory.QUEUE_BATCH = 4
LobbyDirectory.QUEUE_MAX_S = 120

-- Someone waiting in line for a seat: `key` (a player or party leader),
-- `kind`, `since`; `members()` -> (the players to seat, the party data) or
-- nil when they can no longer go; `done(ok, reason, lobby, players)` once
-- seated or out of the line.
export type QueueEntry = {
	key: string,
	kind: string,
	since: number,
	members: () -> ({ any }?, { [string]: any }?),
	done: (boolean, string?, PublicLobbies.Lobby?, { any }?) -> (),
}

export type Directory = typeof(setmetatable(
	{} :: {
		deps: { [string]: any },
		_lobbies: { PublicLobbies.Lobby },
		_refreshIn: number,
		_busy: boolean,
		_queue: { QueueEntry },
		_queueIn: number,
		_queueBusy: boolean,
		_lockRetryAt: number,
		demand: { [string]: PublicLobbies.Demand },
	},
	LobbyDirectory
))

function LobbyDirectory.new(deps: { [string]: any }): Directory
	return setmetatable({
		deps = deps,
		_lobbies = {},
		_refreshIn = 0,
		_busy = false,
		_queue = {},
		_queueIn = 0,
		_queueBusy = false,
		_lockRetryAt = -math.huge,
		demand = {},
	}, LobbyDirectory)
end

function LobbyDirectory._log(self: Directory, text: string)
	local log = self.deps.log
	if log then
		log("[Lobbies] " .. text)
	end
end

function LobbyDirectory._pause(self: Directory, attempt: number)
	local wait = self.deps.wait
	if wait then
		wait(0.15 + self.deps.rand() * 0.4 * attempt)
	end
end

-- The cached lobbies (refreshed every REFRESH_S by tick).
function LobbyDirectory.lobbies(self: Directory): { PublicLobbies.Lobby }
	return self._lobbies
end

-- What clients see: open lobbies that can still be joined (earliest first),
-- then up to MAX_LIVE_LISTED running matches to watch (most players first).
function LobbyDirectory.view(self: Directory): { { [string]: any } }
	local now = self.deps.now()
	local out = {}
	local live = {}
	for _, l in self._lobbies do
		if l.status == "open" and l.starts > now then
			if PublicLobbies.joinable(l, now) then
				table.insert(out, PublicLobbies.publicView(l, now))
			end
		elseif PublicLobbies.watchable(l, now) then
			table.insert(live, l)
		end
	end
	table.sort(live, function(a, b)
		if a.players ~= b.players then
			return a.players > b.players
		end
		return a.starts > b.starts
	end)
	for i = 1, math.min(#live, PublicLobbies.MAX_LIVE_LISTED) do
		table.insert(out, PublicLobbies.publicView(live[i], now))
	end
	return out
end

-- Teleports `player` to a running match as a spectator (no seat is taken).
function LobbyDirectory.spectate(self: Directory, player: any, id: string): (boolean, string?, PublicLobbies.Lobby?)
	local deps = self.deps
	local ok, v = pcall(deps.store.get, id)
	local l = if ok then PublicLobbies.decode(v) else nil
	if l == nil or not PublicLobbies.watchable(l, deps.now()) then
		return false, "That match has ended.", nil
	end
	local sent, err = deps.teleport.send({ player }, l.code, { lobby = l.id, spectate = true })
	if not sent then
		return false, err or "The teleport failed. Try again.", l
	end
	return true, nil, l
end

-- Per frame: refresh the list and top it up now and then. Store calls
-- yield, so the refresh runs in its own thread (`spawn`: task.spawn live).
function LobbyDirectory.tick(self: Directory, dt: number, spawn: ((() -> ()) -> ())?)
	self._refreshIn -= dt
	if self._refreshIn > 0 or self._busy then
		return
	end
	self._refreshIn = LobbyDirectory.REFRESH_S
	self._busy = true
	local function run()
		local ok, err = pcall(function()
			LobbyDirectory.refresh(self)
		end)
		if not ok then
			self:_log("refresh failed: " .. tostring(err))
		end
		self._busy = false
	end
	if spawn then
		spawn(run)
	else
		run()
	end
end

-- Reads the store, drops stale lobbies, creates missing ones (when this hub
-- holds the lock).
function LobbyDirectory.refresh(self: Directory)
	local deps = self.deps
	local now = deps.now()
	local list: { PublicLobbies.Lobby } = {}
	for _, v in deps.store.list() do
		local l = PublicLobbies.decode(v)
		if l == nil then
			continue
		end
		if l.status == "open" and l.starts < now - LobbyDirectory.STALE_AFTER_S then
			-- nobody joined before the start: gone
			pcall(deps.store.remove, l.id)
			continue
		end
		if l.status == "open" and not PublicLobbies.plausible(l, now) then
			-- written with a wrong clock: not listed, not counted
			continue
		end
		table.insert(list, l)
	end
	table.sort(list, function(a, b)
		return a.starts < b.starts
	end)
	self._lobbies = list
	local oldest = now
	for _, l in list do
		oldest = math.min(oldest, l.created)
	end
	local window = math.min(PublicLobbies.DEMAND_WINDOW_S, now - oldest)
	local kinds = PublicLobbies.kinds(deps.worldAvailable == true)
	for _, k in kinds do
		self.demand[k.kind] = PublicLobbies.demand(list, now, k.kind, window)
	end
	-- World's lobbies keep clear of the free-for-alls' starts (an FFA join
	-- takes World's seats too, so the soonest alternates).
	local want = {}
	local ffaStarts = {}
	for _, l in list do
		if l.kind == PublicLobbies.KIND_FFA and l.status == "open" and l.starts > now then
			table.insert(ffaStarts, l.starts)
		end
	end
	for _, k in kinds do
		local avoid = nil
		if k.kind == PublicLobbies.KIND_WORLD then
			table.sort(ffaStarts)
			avoid = ffaStarts
		end
		for _, starts in PublicLobbies.missingStarts(list, now, k.kind, k.target, self.demand[k.kind], avoid) do
			table.insert(want, { starts = starts, kind = k.kind })
			if k.kind == PublicLobbies.KIND_FFA then
				table.insert(ffaStarts, starts)
			end
		end
	end
	if #want > 0 and now >= self._lockRetryAt then
		if deps.store.lock("scheduler", LobbyDirectory.LOCK_TTL_S) then
			self._lockRetryAt = -math.huge
			for _, w in want do
				local ok, l = pcall(LobbyDirectory.create, self, w.starts, w.kind)
				if ok and l ~= nil then
					table.insert(self._lobbies, l)
				elseif not ok then
					self:_log("create failed: " .. tostring(l))
				end
			end
		else
			-- another hub has it: it makes the lobbies meanwhile
			local r = LobbyDirectory.LOCK_RETRY_S
			self._lockRetryAt = now + r[1] + deps.rand() * (r[2] - r[1])
		end
	end
end

-- Creates one lobby of `kind` starting at `starts`: its OpenFront config,
-- a reserved server and a store record.
function LobbyDirectory.create(self: Directory, starts: number, kind: string): PublicLobbies.Lobby?
	local deps = self.deps
	local config = deps.config(kind)
	if config == nil then
		return nil
	end
	local size = if type(deps.serverSize) == "function" then deps.serverSize() else nil
	local code, psid = deps.teleport.reserve()
	local now = deps.now()
	local l: PublicLobbies.Lobby = {
		id = deps.newId(),
		kind = kind,
		config = config,
		max = PublicLobbies.maxOf(config, size),
		starts = starts,
		created = now,
		players = 0,
		status = "open",
		code = code,
		psid = psid,
	}
	local ttl = math.max(60, starts - now + PublicLobbies.RECORD_TTL_AFTER_START_S)
	deps.store.put(l, ttl)
	if psid ~= nil then
		deps.store.bindPsid(psid, l.id, ttl)
	end
	self:_log(string.format("created %s (%s, %s, %d players) starting in %ds", l.id, kind, tostring(config.gameMap), l.max, starts - now))
	return l
end

function LobbyDirectory._uid(self: Directory, p: any): string
	local f = self.deps.uidOf
	if f ~= nil then
		return f(p)
	end
	local ok, u = pcall(function()
		return p.UserId
	end)
	return if ok and u ~= nil then tostring(u) else tostring(p)
end

-- This hub's open lobbies a join of `kind` may take that still take joins,
-- soonest first (its own kind first on a tie).
function LobbyDirectory._openOf(self: Directory, kind: string, now: number): { PublicLobbies.Lobby }
	local out = {}
	local kinds = PublicLobbies.takesFrom(kind)
	for _, l in self._lobbies do
		if l.status == "open" and table.find(kinds, l.kind) ~= nil and l.starts > now + PublicLobbies.JOIN_CLOSE_S and PublicLobbies.plausible(l, now) then
			table.insert(out, l)
		end
	end
	table.sort(out, function(a, b)
		if a.starts ~= b.starts then
			return a.starts < b.starts
		end
		return a.kind == kind and b.kind ~= kind
	end)
	return out
end

-- Seats `players` (one player, or a party: `opts.party` = { key, uids,
-- leader }) in the soonest public match of `kind` with room for all of them,
-- in one store step, and sends them there (yields). `opts.wanted()`: checked
-- before the teleport (false: the seats go back). Returns ok, reason, lobby;
-- reason NO_ROOM when no lobby has room now, "studio" when teleports can't
-- run (the caller plays the lobby on this server).
function LobbyDirectory.joinPublic(self: Directory, players: { any }, kind: string, opts: { [string]: any }?): (boolean, string?, PublicLobbies.Lobby?)
	local deps = self.deps
	local o: { [string]: any } = opts or {}
	local n = math.max(1, #players)
	local uids = {}
	for _, p in players do
		table.insert(uids, self:_uid(p))
	end
	local now = deps.now()
	local spec = PublicLobbies.takeSpec(kind, n, uids, now, o.id)
	local open = self:_openOf(kind, now)
	local ids = {}
	for _, l in open do
		table.insert(ids, l.id)
	end
	spec.candidates = ids
	local ok, v = false, nil
	for attempt = 1, LobbyDirectory.JOIN_TRIES do
		ok, v = pcall(deps.store.take, spec)
		if ok then
			break
		end
		if attempt < LobbyDirectory.JOIN_TRIES then
			self:_pause(attempt)
		end
	end
	local l: PublicLobbies.Lobby? = nil
	if ok then
		l = PublicLobbies.decode(v)
		if l == nil then
			return false, LobbyDirectory.NO_ROOM, nil
		end
	else
		-- the store unreachable: the soonest lobby with room in this hub's copy
		-- (the match server's presence count corrects the record)
		for _, c in open do
			if PublicLobbies.fits(c, spec) and c.code ~= nil then
				c.players += n
				l = table.clone(c)
				break
			end
		end
		if l == nil then
			self:_log("join failed: " .. tostring(v))
			return false, LobbyDirectory.UNREACHABLE, nil
		end
		self:_log("join without a reservation (store busy): " .. tostring(v))
	end
	local lobby = l :: PublicLobbies.Lobby
	local function giveBack()
		if ok then
			pcall(deps.store.release, lobby.id, uids)
		end
	end
	if lobby.code == nil then
		giveBack()
		return false, "That match is gone.", nil
	end
	if o.wanted ~= nil and not o.wanted() then
		giveBack()
		return false, "cancelled", lobby
	end
	local data: { [string]: any } = { lobby = lobby.id }
	if n > 1 and o.party ~= nil then
		data.party = { key = o.party.key, uids = o.party.uids, leader = o.party.leader }
	end
	local sent, err = deps.teleport.send(players, lobby.code, data)
	if not sent then
		-- Studio: the seats stay; the caller plays this lobby here
		if err ~= "studio" then
			giveBack()
		end
		return false, err or "The teleport failed. Try again.", lobby
	end
	-- mirror the seats locally so the list shows them at once
	for _, c in self._lobbies do
		if c.id == lobby.id then
			c.players = lobby.players
		end
	end
	return true, nil, lobby
end

-- Gives back the seats of `uids` in lobby `id` (a teleport that failed
-- after it began). Yields.
function LobbyDirectory.release(self: Directory, id: string, uids: { string }): number
	local ok, _res, n = pcall(self.deps.store.release, id, uids)
	if not ok then
		self:_log("release failed: " .. tostring(_res))
		return 0
	end
	return tonumber(n) or 0
end

-- Puts someone in line for a seat; one entry per key (a new one replaces it).
function LobbyDirectory.enqueue(self: Directory, e: QueueEntry)
	self:dequeue(e.key)
	table.insert(self._queue, e)
end

-- Takes `key` out of the line (true if it was in it). Its `done` is not called.
function LobbyDirectory.dequeue(self: Directory, key: string): boolean
	for i, e in self._queue do
		if e.key == key then
			table.remove(self._queue, i)
			return true
		end
	end
	return false
end

function LobbyDirectory.queued(self: Directory, key: string): QueueEntry?
	for _, e in self._queue do
		if e.key == key then
			return e
		end
	end
	return nil
end

-- One pass over the line: oldest first, up to QUEUE_BATCH store calls; per
-- kind, once n seats were missing, nobody needing n or more is tried this
-- pass (someone smaller may still fit). Yields.
function LobbyDirectory.serveQueue(self: Directory)
	local now = self.deps.now()
	local calls = 0
	local blocked: { [string]: number } = {}
	for _, e in table.clone(self._queue) do
		if calls >= LobbyDirectory.QUEUE_BATCH then
			break
		end
		if self:queued(e.key) ~= e then
			continue -- (left the line meanwhile)
		end
		if now - e.since > LobbyDirectory.QUEUE_MAX_S then
			self:dequeue(e.key)
			e.done(false, "timeout", nil, nil)
			continue
		end
		local players, party = e.members()
		if players == nil or #players == 0 then
			self:dequeue(e.key)
			e.done(false, "gone", nil, nil)
			continue
		end
		local n = #players
		if blocked[e.kind] ~= nil and n >= blocked[e.kind] then
			continue
		end
		calls += 1
		local ok, reason, l = self:joinPublic(players, e.kind, {
			party = party,
			wanted = function(): boolean
				return self:queued(e.key) == e
			end,
		})
		if ok then
			self:dequeue(e.key)
			e.done(true, nil, l, players)
		elseif reason == LobbyDirectory.NO_ROOM then
			blocked[e.kind] = math.min(blocked[e.kind] or math.huge, n)
		elseif reason ~= "cancelled" then
			self:dequeue(e.key)
			e.done(false, reason, l, players)
		end
	end
end

-- Per frame: serve the line every QUEUE_RETRY_S (in its own thread).
function LobbyDirectory.tickQueue(self: Directory, dt: number, spawn: ((() -> ()) -> ())?)
	self._queueIn -= dt
	if self._queueIn > 0 or self._queueBusy or #self._queue == 0 then
		return
	end
	self._queueIn = LobbyDirectory.QUEUE_RETRY_S
	self._queueBusy = true
	local function run()
		local ok, err = pcall(function()
			LobbyDirectory.serveQueue(self)
		end)
		if not ok then
			self:_log("queue failed: " .. tostring(err))
		end
		self._queueBusy = false
	end
	if spawn then
		spawn(run)
	else
		run()
	end
end

return LobbyDirectory
