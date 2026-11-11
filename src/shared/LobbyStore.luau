--!strict
-- Ported from RoWorld 2be8efb (src/server/Lobbies/LobbyStore.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- Lobby storage for the hub and match servers (PublicLobbies records):
--   LobbyStore.memory(jobId, now)  live servers: MemoryStoreService, shared by every
--                                  server of the experience. A sorted map of lobby
--                                  records (sort key = start time), a hash map
--                                  PrivateServerId -> lobby id, and a sorted map of
--                                  short locks.
--   LobbyStore.localstore(now)     one process (Lune tests; Studio, where every
--                                  "server" is this one).
-- Both expose: list(), get(id), put(lobby, ttlS), update(id, fn), remove(id),
-- lock(name, ttlS), bindPsid(psid, id, ttlS), lobbyForPsid(psid), take(spec),
-- release(id, uids). MemoryStore calls yield and may throw: callers pcall.
-- Roblox services are reached only when `memory` is called, so Lune loads it.
-- (RoWorld's lobby web service, its failover and request signing are not ported.)

local PublicLobbies = require(script.Parent.PublicLobbies)

local LobbyStore = {}

LobbyStore.NAMESPACE = "conquest_lobbies_v1"
LobbyStore.LIST_LIMIT = 50
-- update() keeps a record this long when it has to make one.
LobbyStore.UPDATE_TTL_S = 15 * 60

export type Store = {
	list: () -> { any },
	get: (id: string) -> any,
	put: (l: any, ttlS: number) -> (),
	update: (id: string, fn: (any) -> any) -> any,
	remove: (id: string) -> (),
	lock: (name: string, ttlS: number, owner: string?) -> boolean,
	bindPsid: (psid: string, id: string, ttlS: number) -> (),
	lobbyForPsid: (psid: string) -> any,
	take: (spec: PublicLobbies.TakeSpec) -> any,
	release: (id: string, uids: { string }) -> (any, number),
}

-- `take` over `update` (stores that can't search): the spec's candidates in
-- order (or its one `id`); the first that fits gets the seats.
local function takeViaUpdate(store: any, spec: PublicLobbies.TakeSpec): any
	local ids: { string } = if spec.id ~= nil then { spec.id } else (spec.candidates or {})
	for _, id in ids do
		local got: any = nil
		store.update(id, function(v: any): any?
			-- (UpdateAsync may run this again on a newer record: only the last run counts)
			got = nil
			local l = PublicLobbies.decode(v)
			if l == nil or not PublicLobbies.fits(l, spec) then
				return nil
			end
			got = PublicLobbies.seated(l, spec)
			return got
		end)
		if got ~= nil then
			return got
		end
	end
	return nil
end

-- `release` over `update`: the record after, and how many seats went back.
local function releaseViaUpdate(store: any, id: string, uids: { string }): (any, number)
	local n = 0
	local after: any = nil
	store.update(id, function(v: any): any?
		n = 0
		local l = PublicLobbies.decode(v)
		if l == nil then
			return nil
		end
		local c, k = PublicLobbies.released(l, uids)
		after = c
		n = k
		return if k > 0 then c else nil
	end)
	return after, n
end

-- MemoryStoreService-backed store. `now`: the shared clock (lock expiry
-- times are compared across servers).
function LobbyStore.memory(jobId: string, now: (() -> number)?): Store
	local MSS = game:GetService("MemoryStoreService")
	return LobbyStore.memoryWith(
		MSS:GetSortedMap(LobbyStore.NAMESPACE .. "_lobbies"),
		MSS:GetHashMap(LobbyStore.NAMESPACE .. "_psid"),
		MSS:GetSortedMap(LobbyStore.NAMESPACE .. "_locks"),
		jobId,
		now,
		{ Enum.SortDirection.Ascending, Enum.SortDirection.Descending }
	)
end

-- The memory store over given maps (tests pass fakes). `directions`: the two
-- sort directions to list in (Enum values live, anything in tests).
function LobbyStore.memoryWith(lobbies: any, psids: any, locks: any, jobId: string, now: (() -> number)?, directions: { any }): Store
	local clock: () -> number = now or function(): number
		return os.time()
	end
	local store: any = {}

	-- Both ends of the start-time order: the oldest records (running matches)
	-- and the newest (the open lobbies), so many live matches never push the
	-- open lobbies off the list.
	function store.list(): { any }
		local out = {}
		local seen = {}
		for _, dir in directions do
			local items = lobbies:GetRangeAsync(dir, LobbyStore.LIST_LIMIT)
			for _, it in items do
				if not seen[it.key] then
					seen[it.key] = true
					table.insert(out, it.value)
				end
			end
		end
		return out
	end

	function store.get(id: string): any
		return (lobbies:GetAsync(id))
	end

	function store.put(l: any, ttlS: number)
		lobbies:SetAsync(l.id, l, math.floor(ttlS), l.starts)
	end

	-- Atomic read-modify-write; `fn` returns the new record or nil (unchanged).
	function store.update(id: string, fn: (any) -> any): any
		return lobbies:UpdateAsync(id, function(old: any, _sort: any): (any, any)
			local new = fn(old)
			if new == nil then
				return nil
			end
			return new, new.starts
		end, LobbyStore.UPDATE_TTL_S)
	end

	function store.remove(id: string)
		lobbies:RemoveAsync(id)
	end

	-- A short lease: true when this server holds `name` now.
	function store.lock(name: string, ttlS: number, _owner: string?): boolean
		local got = false
		local t = clock()
		locks:UpdateAsync(name, function(old: any): any
			local exp = if type(old) == "table" then (tonumber(old.exp) or 0) else 0
			-- held, unless it claims to last far longer than any lease (a wrong clock wrote it)
			if type(old) == "table" and old.owner ~= jobId and exp > t and exp <= t + ttlS + 60 then
				return nil
			end
			got = true
			return { owner = jobId, exp = t + ttlS }
		end, ttlS + 5)
		return got
	end

	function store.bindPsid(psid: string, id: string, ttlS: number)
		psids:SetAsync(psid, id, math.floor(ttlS))
	end

	function store.lobbyForPsid(psid: string): any
		local id = psids:GetAsync(psid)
		if type(id) ~= "string" then
			return nil
		end
		return (lobbies:GetAsync(id))
	end

	function store.take(spec: PublicLobbies.TakeSpec): any
		return takeViaUpdate(store, spec)
	end

	function store.release(id: string, uids: { string }): (any, number)
		return releaseViaUpdate(store, id, uids)
	end

	return store :: Store
end

-- One process only: records expire by `now`, and take() can search.
function LobbyStore.localstore(now: (() -> number)?): Store
	local clock: () -> number = now or function(): number
		return os.time()
	end
	local rows: { [string]: { value: any, exp: number } } = {}
	local psidRows: { [string]: string } = {}
	local lockRows: { [string]: { owner: string, exp: number } } = {}
	local store: any = {}

	local function live(id: string): any
		local r = rows[id]
		if r == nil then
			return nil
		end
		if r.exp <= clock() then
			rows[id] = nil
			return nil
		end
		return table.clone(r.value)
	end

	function store.list(): { any }
		local out = {}
		for id in rows do
			local v = live(id)
			if v ~= nil then
				table.insert(out, v)
			end
		end
		table.sort(out, function(a, b)
			return a.starts < b.starts
		end)
		return out
	end

	function store.get(id: string): any
		return live(id)
	end

	function store.put(l: any, ttlS: number)
		rows[l.id] = { value = table.clone(l), exp = clock() + ttlS }
	end

	function store.update(id: string, fn: (any) -> any): any
		local new = fn(live(id))
		if new == nil then
			return nil
		end
		local exp = if rows[id] then rows[id].exp else clock() + LobbyStore.UPDATE_TTL_S
		rows[id] = { value = table.clone(new), exp = exp }
		return new
	end

	function store.remove(id: string)
		rows[id] = nil
	end

	function store.lock(name: string, ttlS: number, owner: string?): boolean
		local who = owner or "local"
		local r = lockRows[name]
		local t = clock()
		if r ~= nil and r.owner ~= who and r.exp > t and r.exp <= t + ttlS + 60 then
			return false
		end
		lockRows[name] = { owner = who, exp = t + ttlS }
		return true
	end

	function store.bindPsid(psid: string, id: string, _ttlS: number)
		psidRows[psid] = id
	end

	function store.lobbyForPsid(psid: string): any
		local id = psidRows[psid]
		return if id then live(id) else nil
	end

	function store.take(spec: PublicLobbies.TakeSpec): any
		if spec.id == nil and spec.candidates == nil then
			local ids = {}
			for _, v in store.list() do
				table.insert(ids, v.id)
			end
			spec = table.clone(spec)
			spec.candidates = ids
		end
		return takeViaUpdate(store, spec)
	end

	function store.release(id: string, uids: { string }): (any, number)
		return releaseViaUpdate(store, id, uids)
	end

	return store :: Store
end

return LobbyStore
