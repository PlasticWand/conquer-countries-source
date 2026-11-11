--!strict
-- Ported from RoWorld 2be8efb (src/server/Lobbies/MatchHost.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- The match side of a public lobby: runs on the lobby's reserved server.
-- Finds its lobby record (by the server's PrivateServerId), keeps the
-- record's player count current while the lobby is open and gives back the
-- seats of players who left or never came, says when the match starts (the
-- lobby's start, held back while nobody has arrived so an early teleport
-- doesn't start an empty match), marks the lobby started (it leaves the
-- joinable lists and shows as live: a heartbeat keeps it watchable), and
-- removes the record when the match is over. Pure with injected deps:
--   deps = { store = LobbyStore, psid = string, now = () -> number, log = ((string) -> ())? }
-- (RoWorld's early-start vote and bot-player fill are not ported: OpenFront's
-- nations and tribes fill the map.)

local PublicLobbies = require(script.Parent.PublicLobbies)

local MatchHost = {}
MatchHost.__index = MatchHost

MatchHost.SYNC_S = 3.0
-- Seconds between lookups while the record isn't found yet (store lag).
MatchHost.LOOKUP_RETRY_S = 2.0
-- The match waits at least this long after the first human arrives (their
-- client boots and loads the map).
MatchHost.MIN_WAIT_AFTER_FIRST_S = 8

export type Host = typeof(setmetatable(
	{} :: {
		deps: { [string]: any },
		lobby: PublicLobbies.Lobby?,
		started: boolean,
		finished: boolean,
		released: number,
		_beatIn: number,
		_firstArrival: number?,
		_foundAt: number?,
		_syncIn: number,
		_lookupIn: number,
		_present: number,
		_presentUids: { [string]: boolean },
		_arrived: { [string]: boolean },
		_busy: boolean,
	},
	MatchHost
))

function MatchHost.new(deps: { [string]: any }): Host
	return setmetatable({
		deps = deps,
		lobby = nil,
		started = false,
		finished = false,
		released = 0,
		_beatIn = 0,
		_firstArrival = nil,
		_foundAt = nil,
		_syncIn = 0,
		_lookupIn = 0,
		_present = 0,
		_presentUids = {},
		_arrived = {},
		_busy = false,
	}, MatchHost)
end

function MatchHost._log(self: Host, text: string)
	if self.deps.log then
		self.deps.log("[MatchHost] " .. text)
	end
end

-- Finds the lobby record (yields). True once known.
function MatchHost.lookup(self: Host): boolean
	if self.lobby ~= nil then
		return true
	end
	local ok, v = pcall(self.deps.store.lobbyForPsid, self.deps.psid)
	if ok then
		self.lobby = PublicLobbies.decode(v)
	end
	local l = self.lobby
	if l ~= nil then
		self._foundAt = self.deps.now()
		self:_log(string.format("lobby %s (%s, %s, %d players), starts in %ds", l.id, l.kind, tostring(l.config.gameMap), l.max, l.starts - self.deps.now()))
	end
	return l ~= nil
end

-- Who is here (user ids of the humans who came to play). The first arrival
-- holds the start for MIN_WAIT_AFTER_FIRST_S.
function MatchHost.setRoster(self: Host, uids: { string })
	local here: { [string]: boolean } = {}
	for _, u in uids do
		here[u] = true
		self._arrived[u] = true
	end
	self._presentUids = here
	self._present = #uids
	if #uids > 0 and self._firstArrival == nil then
		self._firstArrival = self.deps.now()
	end
end

-- Seconds until the match should start (nil while the lobby is unknown).
function MatchHost.startsIn(self: Host): number?
	local l = self.lobby
	if l == nil then
		return nil
	end
	local now = self.deps.now()
	local at = l.starts
	-- never wait past the longest a lobby can be scheduled ahead
	if self._foundAt ~= nil then
		at = math.min(at, self._foundAt + PublicLobbies.MAX_AHEAD_S)
	end
	if self._firstArrival ~= nil then
		at = math.max(at, self._firstArrival + MatchHost.MIN_WAIT_AFTER_FIRST_S)
	end
	return math.max(0, at - now)
end

-- Per frame: look up / sync / beat the record (in a spawned thread).
function MatchHost.tick(self: Host, dt: number, spawn: ((() -> ()) -> ())?)
	if self._busy then
		return
	end
	local run: (() -> ())? = nil
	if self.lobby == nil then
		self._lookupIn -= dt
		if self._lookupIn <= 0 then
			self._lookupIn = MatchHost.LOOKUP_RETRY_S
			run = function()
				self:lookup()
			end
		end
	elseif not self.started then
		self._syncIn -= dt
		if self._syncIn <= 0 then
			self._syncIn = MatchHost.SYNC_S
			run = function()
				self:_sync()
			end
		end
	elseif not self.finished then
		self._beatIn -= dt
		if self._beatIn <= 0 then
			self._beatIn = PublicLobbies.LIVE_BEAT_S
			run = function()
				self:_beat()
			end
		end
	end
	if run then
		self._busy = true
		local body = run
		local function wrapped()
			local ok, err = pcall(function()
				body()
			end)
			if not ok then
				self:_log("sync failed: " .. tostring(err))
			end
			self._busy = false
		end
		if spawn then
			spawn(wrapped)
		else
			wrapped()
		end
	end
end

-- While open: the record's count is at least the humans present (hubs add
-- seats for players still on their way), and the seats of players who left,
-- or never came, go back so hubs seat others in them.
function MatchHost._sync(self: Host)
	local l = self.lobby
	if l == nil then
		return
	end
	local present = self._present
	local now = self.deps.now()
	local lapsed: { string } = {}
	local new = self.deps.store.update(l.id, function(v: any): any?
		local cur = PublicLobbies.decode(v)
		if cur == nil then
			return nil
		end
		lapsed = PublicLobbies.lapsedSeats(cur, self._presentUids, self._arrived, now)
		if cur.players >= present then
			return nil
		end
		cur.players = present
		return cur
	end)
	local d = PublicLobbies.decode(new)
	if d then
		self.lobby = d
	end
	if #lapsed > 0 then
		local after, n = self.deps.store.release(l.id, lapsed)
		if (tonumber(n) or 0) > 0 then
			self.released += n
			self:_log(string.format("gave back %d seat(s) of players who left or never came", n))
			local da = PublicLobbies.decode(after)
			if da then
				self.lobby = da
			end
		end
	end
end

-- While the match runs: the record stays fresh (watchable) with the humans here.
function MatchHost._beat(self: Host)
	local l = self.lobby
	if l == nil then
		return
	end
	local now = self.deps.now()
	local present = self._present
	self.deps.store.update(l.id, function(v: any): any?
		local cur = PublicLobbies.decode(v)
		if cur == nil then
			return nil
		end
		cur.beat = now
		cur.players = present
		return cur
	end)
end

-- The match is starting: the lobby leaves the joinable lists (yields).
function MatchHost.start(self: Host, humans: number)
	self.started = true
	local l = self.lobby
	if l == nil then
		return
	end
	pcall(self.deps.store.update, l.id, function(v: any): any?
		local cur = PublicLobbies.decode(v)
		if cur == nil then
			return nil
		end
		cur.status = "started"
		cur.players = humans
		cur.beat = self.deps.now()
		return cur
	end)
	self:_log(string.format("starting %s with %d humans", l.id, humans))
end

-- The match is over: its record goes (nothing left to watch). Yields.
function MatchHost.finish(self: Host)
	if self.finished then
		return
	end
	self.finished = true
	local l = self.lobby
	if l ~= nil then
		pcall(self.deps.store.remove, l.id)
	end
end

return MatchHost
