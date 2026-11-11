--!strict
-- Ported from RoWorld 2be8efb (src/server/Lobbies/LobbyRules.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- Public lobbies across servers: pure rules, no services (Lune tests them;
-- docs/openfront-port/LOBBIES_PLAN.md). A lobby is one upcoming public match:
-- its OpenFront game config (map, mode, teams, size from MapPlaylist), a start
-- time on the shared clock, and the reserved server that will run it. Hub
-- servers list the lobbies to their players and seat joiners; the match
-- server waits for the start and plays the match (nations and tribes fill
-- the map, as OpenFront's public games do).
--   * Kinds: "ffa" (OpenFront's FFA playlist), "world" (World, always) and
--     "team" (OpenFront's team playlist). One joinable lobby of each is kept
--     open, more while the demand calls for them (missing_starts).
--   * Each lobby is listed at most LOBBY_OPEN_S (90 s) ahead of its start;
--     joining closes JOIN_CLOSE_S before it (a teleport takes a few seconds).
--   * Seats (Quick Play): a join takes seats in the soonest lobby of its kind
--     with room in one store update; the record's ledger knows who holds them,
--     so a seat whose player never arrives, or left, is given back.
-- Differences from RoWorld: the map, mode and size come from OpenFront's
-- MapPlaylist (no map list, weights or team draws of RoWorld's own), maps
-- are played at full size (RoWorld: 80 %), and no bot players are added.

local PublicLobbies = {}

PublicLobbies.KIND_FFA = "ffa"
PublicLobbies.KIND_WORLD = "world"
PublicLobbies.KIND_TEAM = "team"

PublicLobbies.LOBBY_OPEN_S = 90
PublicLobbies.LOBBY_INTERVAL_S = 45
PublicLobbies.MIN_LEAD_S = 45
-- World's lobbies keep this far from the free-for-alls' starts, so the two
-- don't start on the same second (an FFA join also takes World's seats).
PublicLobbies.WORLD_STAGGER_S = 22
PublicLobbies.JOIN_CLOSE_S = 6
-- A record lives this long past its start (the match server reads it on boot).
PublicLobbies.RECORD_TTL_AFTER_START_S = 15 * 60
-- A running match's server refreshes its record (`beat`) this often; hubs
-- list it to watch only while the last beat is recent.
PublicLobbies.LIVE_BEAT_S = 30
PublicLobbies.LIVE_STALE_S = 100
PublicLobbies.MAX_LIVE_LISTED = 8
-- The seat ledger: entries a record keeps at most; a seat whose player has
-- not reached the match server this long after taking it is given back.
PublicLobbies.MAX_SEATS = 60
PublicLobbies.ARRIVE_S = 30
-- Demand: seats taken over this window measure it; free seats are kept for
-- FILL_AHEAD_S of joins at that rate, in at most MAX_OPEN_PER_KIND lobbies,
-- starting MIN_INTERVAL_S..LOBBY_INTERVAL_S apart.
PublicLobbies.DEMAND_WINDOW_S = 120
PublicLobbies.FILL_AHEAD_S = 20
PublicLobbies.MAX_OPEN_PER_KIND = 4
PublicLobbies.MIN_INTERVAL_S = 8
-- No lobby is scheduled further ahead than this; a record beyond it was
-- written with a wrong clock and is ignored.
PublicLobbies.MAX_AHEAD_S = PublicLobbies.LOBBY_OPEN_S + 2 * PublicLobbies.LOBBY_INTERVAL_S + 120
-- Fallback size when a config has none.
PublicLobbies.DEFAULT_MAX = 50

export type Lobby = {
	id: string,
	kind: string, -- KIND_*
	config: { [string]: any }, -- the OpenFront game config the match plays
	max: number,
	starts: number, -- shared-clock seconds
	created: number,
	players: number, -- humans in (or on their way to) the match server
	status: string, -- "open" | "started" | "closed"
	beat: number?, -- the running match's last heartbeat
	code: string?, -- reserved-server access code (server only; never sent to clients)
	psid: string?, -- reserved server's PrivateServerId
	seats: { [string]: number }?, -- user id -> when its seat was taken
}

-- What `take` asks for: `n` seats for `uids` in the soonest open lobby of one
-- of `kinds` with room that still takes joins; `id`: only that lobby;
-- `candidates`: lobby ids to try in order (stores that can't search).
export type TakeSpec = {
	kind: string,
	kinds: { string },
	n: number,
	uids: { string },
	at: number,
	close_before: number,
	start_before: number,
	id: string?,
	candidates: { string }?,
}

export type Demand = { rate: number, size: number }

-- The kinds a join of `kind` may seat in: a free-for-all join takes World's
-- lobbies too (the soonest that fits wins); World and team joins only their own.
function PublicLobbies.takesFrom(kind: string): { string }
	if kind == PublicLobbies.KIND_FFA then
		return { PublicLobbies.KIND_FFA, PublicLobbies.KIND_WORLD }
	end
	return { kind }
end

-- The kinds offered, in the menu's order, and the joinable lobbies each keeps
-- open at least.
function PublicLobbies.kinds(worldAvailable: boolean): { { kind: string, target: number } }
	local out = { { kind = PublicLobbies.KIND_FFA, target = 1 } }
	if worldAvailable then
		table.insert(out, { kind = PublicLobbies.KIND_WORLD, target = 1 })
	end
	table.insert(out, { kind = PublicLobbies.KIND_TEAM, target = 1 })
	return out
end

function PublicLobbies.isKind(kind: any): boolean
	return kind == PublicLobbies.KIND_FFA or kind == PublicLobbies.KIND_WORLD or kind == PublicLobbies.KIND_TEAM
end

-- The lobby size: the config's (OpenFront's lobby size for the map), never
-- more than a server holds.
function PublicLobbies.maxOf(config: { [string]: any }, serverSize: number?): number
	local n = if type(config.maxPlayers) == "number" then math.floor(config.maxPlayers) else PublicLobbies.DEFAULT_MAX
	if type(serverSize) == "number" and serverSize >= 2 then
		n = math.min(n, math.floor(serverSize))
	end
	return math.clamp(n, 1, 200)
end

function PublicLobbies.takeSpec(kind: string, n: number, uids: { string }, now: number, id: string?): TakeSpec
	return {
		kind = kind,
		kinds = PublicLobbies.takesFrom(kind),
		n = n,
		uids = uids,
		at = now,
		close_before = now + PublicLobbies.JOIN_CLOSE_S,
		start_before = now + PublicLobbies.MAX_AHEAD_S,
		id = id,
	}
end

-- True when `l` can seat what `spec` asks for.
function PublicLobbies.fits(l: Lobby, spec: TakeSpec): boolean
	return l.status == "open"
		and table.find(spec.kinds, l.kind) ~= nil
		and l.starts > spec.close_before
		and l.starts <= spec.start_before
		and l.players + spec.n <= l.max
		and (spec.id == nil or spec.id == l.id)
end

-- `l` with `spec`'s seats taken (a new table).
function PublicLobbies.seated(l: Lobby, spec: TakeSpec): Lobby
	local c = table.clone(l)
	local seats: { [string]: number } = if l.seats ~= nil then table.clone(l.seats) else {}
	local count = 0
	for _ in seats do
		count += 1
	end
	for _, u in spec.uids do
		if seats[u] == nil and count < PublicLobbies.MAX_SEATS then
			seats[u] = spec.at
			count += 1
		end
	end
	c.players += spec.n
	c.seats = seats
	return c
end

-- `l` with the seats of `uids` given back (only seats in its ledger, only
-- while open): the new record and how many went back.
function PublicLobbies.released(l: Lobby, uids: { string }): (Lobby, number)
	if l.status ~= "open" or l.seats == nil then
		return l, 0
	end
	local seats: { [string]: number } = table.clone(l.seats)
	local n = 0
	for _, u in uids do
		if seats[u] ~= nil then
			seats[u] = nil
			n += 1
		end
	end
	if n == 0 then
		return l, 0
	end
	local c = table.clone(l)
	c.seats = seats
	c.players = math.max(0, l.players - n)
	return c, n
end

-- Seats of a waiting lobby to give back (the match server, before the
-- start): those whose player arrived and left, and those whose player has not
-- arrived ARRIVE_S after taking the seat.
function PublicLobbies.lapsedSeats(l: Lobby, present: { [string]: boolean }, arrived: { [string]: boolean }, now: number): { string }
	local out = {}
	local seats: { [string]: number } = l.seats or {}
	for u, at in seats do
		if present[u] then
			continue
		end
		if arrived[u] or now - at >= PublicLobbies.ARRIVE_S then
			table.insert(out, u)
		end
	end
	table.sort(out)
	return out
end

-- The demand for `kind`: seats taken a second over the lobbies of that kind
-- made in the last DEMAND_WINDOW_S, and their average size.
function PublicLobbies.demand(list: { Lobby }, now: number, kind: string, window: number?): Demand
	local w = math.clamp(window or PublicLobbies.DEMAND_WINDOW_S, 30, PublicLobbies.DEMAND_WINDOW_S)
	local seats, sizes, n = 0, 0, 0
	for _, l in list do
		if l.kind == kind and l.created > now - w and l.created <= now then
			seats += math.min(l.players, l.max)
			sizes += l.max
			n += 1
		end
	end
	return { rate = seats / w, size = if n > 0 then sizes / n else PublicLobbies.DEFAULT_MAX }
end

-- True while players may still join (open, not full, far enough from the start).
function PublicLobbies.joinable(l: Lobby, now: number): boolean
	return l.status == "open" and l.players < l.max and now < l.starts - PublicLobbies.JOIN_CLOSE_S
end

-- Start times of the lobbies of `kind` to create now so that `target`
-- joinable ones exist: after the latest joinable start (or now + MIN_LEAD_S),
-- an interval apart, never more than LOBBY_OPEN_S out. A lobby within half an
-- interval of its start no longer counts, so the next one exists before it
-- closes. `demand` adds lobbies while their free seats would last less than
-- FILL_AHEAD_S. `avoid` (World's: the free-for-alls' starts) moves the first
-- start that falls within WORLD_STAGGER_S of one to just after it.
function PublicLobbies.missingStarts(open: { Lobby }, now: number, kind: string, target: number, demand: Demand?, avoid: { number }?): { number }
	local joinable, free, latest = 0, 0, 0
	local cover = PublicLobbies.LOBBY_INTERVAL_S / 2
	for _, l in open do
		if l.kind == kind and PublicLobbies.joinable(l, now) then
			if l.starts - now > cover then
				joinable += 1
				free += l.max - l.players
			end
			if l.starts > latest then
				latest = l.starts
			end
		end
	end
	local wantFree = 0
	local interval = PublicLobbies.LOBBY_INTERVAL_S
	local size = PublicLobbies.DEFAULT_MAX
	if demand ~= nil and demand.rate > 0 then
		wantFree = demand.rate * PublicLobbies.FILL_AHEAD_S
		size = math.max(1, demand.size)
		interval = math.clamp(size / demand.rate, PublicLobbies.MIN_INTERVAL_S, PublicLobbies.LOBBY_INTERVAL_S)
	end
	local out = {}
	local nextStart = math.max(now + PublicLobbies.MIN_LEAD_S, latest + interval)
	if avoid ~= nil and interval >= PublicLobbies.LOBBY_INTERVAL_S then
		for _, a in avoid do
			if math.abs(nextStart - a) < PublicLobbies.WORLD_STAGGER_S then
				local moved = a + PublicLobbies.WORLD_STAGGER_S
				if moved <= now + PublicLobbies.LOBBY_OPEN_S then
					nextStart = moved
				end
				break
			end
		end
	end
	while joinable < target or (free < wantFree and joinable < math.max(target, PublicLobbies.MAX_OPEN_PER_KIND)) do
		if nextStart > now + PublicLobbies.LOBBY_OPEN_S then
			break
		end
		table.insert(out, nextStart)
		joinable += 1
		free += size
		nextStart += interval
	end
	return out
end

function PublicLobbies.plausible(l: Lobby, now: number): boolean
	return l.starts <= now + PublicLobbies.MAX_AHEAD_S
end

-- A running match anyone may watch (its server is alive and reachable).
function PublicLobbies.watchable(l: Lobby, now: number): boolean
	return l.status == "started" and l.code ~= nil and (l.beat or l.starts) > now - PublicLobbies.LIVE_STALE_S
end

-- What a client sees of a lobby (never the access code or server id).
function PublicLobbies.publicView(l: Lobby, now: number): { [string]: any }
	local live = l.status == "started"
	return {
		id = l.id,
		kind = l.kind,
		mapType = l.config.gameMap,
		gameMode = l.config.gameMode,
		playerTeams = l.config.playerTeams,
		capacity = l.max,
		players = math.min(l.players, l.max),
		startsIn = math.max(0, l.starts - now),
		joinable = PublicLobbies.joinable(l, now),
		live = live,
		elapsed = if live then math.max(0, now - l.starts) else 0,
		watchable = PublicLobbies.watchable(l, now),
	}
end

-- A plain value (string, number, boolean), or at `depth` > 0 a small table
-- of them (OpenFront's publicGameModifiers, disabledUnits, overtime); nil
-- for anything else.
local function plain(x: any, depth: number): any
	local tx = type(x)
	if (tx == "string" and #x <= 80) or tx == "number" or tx == "boolean" then
		return x
	end
	if tx ~= "table" or depth <= 0 then
		return nil
	end
	local out = {}
	local n = 0
	for k, y in x do
		local tk = type(k)
		if (tk == "string" and #k <= 40) or tk == "number" then
			local c = plain(y, depth - 1)
			if c ~= nil and n < 40 then
				out[k] = c
				n += 1
			end
		end
	end
	return out
end

-- A game config read back from a store: string keys with plain values or
-- small tables of them (40 entries at most); nil without a map.
local function decodeConfig(v: any): { [string]: any }?
	if type(v) ~= "table" or type(v.gameMap) ~= "string" then
		return nil
	end
	local out = {}
	local n = 0
	for k, x in v do
		if type(k) == "string" and #k <= 40 and n < 40 then
			local c = plain(x, 1)
			if c ~= nil then
				out[k] = c
				n += 1
			end
		end
	end
	return out
end

-- Sanitises a lobby record read back from a store; nil when unusable.
function PublicLobbies.decode(v: any): Lobby?
	if type(v) ~= "table" or type(v.id) ~= "string" or type(v.starts) ~= "number" or type(v.max) ~= "number" then
		return nil
	end
	local config = decodeConfig(v.config)
	if config == nil or not PublicLobbies.isKind(v.kind) then
		return nil
	end
	-- the seat ledger (an empty one may come back as an array: Roblox writes {} as [])
	local seats: { [string]: number }? = nil
	if type(v.seats) == "table" then
		local ledger: { [string]: number } = {}
		seats = ledger
		local n = 0
		for u, at in v.seats do
			if type(u) == "string" and #u <= 24 and type(at) == "number" and n < PublicLobbies.MAX_SEATS then
				ledger[u] = at
				n += 1
			end
		end
	end
	return {
		id = v.id,
		kind = v.kind,
		config = config,
		max = math.clamp(math.floor(v.max), 1, 200),
		starts = v.starts,
		created = if type(v.created) == "number" then v.created else v.starts,
		players = if type(v.players) == "number" then math.max(0, math.floor(v.players)) else 0,
		status = (if v.status == "started" or v.status == "closed" then v.status else "open") :: string,
		beat = if type(v.beat) == "number" then v.beat else nil,
		code = if type(v.code) == "string" then v.code else nil,
		psid = if type(v.psid) == "string" then v.psid else nil,
		seats = seats,
	}
end

return PublicLobbies
