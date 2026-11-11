--!strict
-- Saved profiles (PLAN_WELCOME M7): one DataStore record per player, guarded
-- by a session lock so two servers never both write the same player (from
-- Stunt Yard's SaveStore, docs/LESSONS.md). The store, clock and wait are
-- injected, so tests drive it under Lune; the server adapter passes the real
-- DataStore. Record key "profile_<userId>": the codec's encode plus
--   lock     { session = string, at = unix seconds }?  nil when released
--   savedAt  unix seconds
-- Rules:
--   * load claims the lock. A live lock held by another session is waited on
--     (that server is usually finishing its final save) and stolen on the
--     last attempt; a lock older than LOCK_STALE_SECONDS is dead and taken.
--   * save writes only while this session still holds the lock; otherwise
--     it reports "lockLost" and changes nothing.
--   * a record this code can't read ("newerSchema", "corrupt") is never
--     overwritten: that player plays unsaved.


export type Store = {
	UpdateAsync: (self: any, key: string, transform: (any) -> ...any) -> ...any,
}

-- How a record is made, read and written (Store/Profile's new, encode and
-- decode; the server's Store passes them).
export type Codec = {
	new: () -> any,
	encode: (any) -> { [string]: any },
	decode: (any) -> (any?, string?),
}

export type Deps = {
	store: Store,
	codec: Codec,
	session: string, -- unique per server
	now: () -> number, -- unix seconds
	wait: (seconds: number) -> (),
	loadAttempts: number,
	retrySeconds: number,
	log: (message: string) -> (),
}

local ProfileStore = {}

ProfileStore.LOCK_STALE_SECONDS = 600 -- holders autosave well inside this
ProfileStore.SAVE_ATTEMPTS = 3

function ProfileStore.key(userId: number): string
	return `profile_{userId}`
end

local function lockHolder(record: any): (string?, number)
	if type(record) == "table" and type(record.lock) == "table" and type(record.lock.session) == "string" and type(record.lock.at) == "number" then
		return record.lock.session, record.lock.at
	end
	return nil, 0
end


local function encode(codec: Codec, profile: any, lock: { session: string, at: number }?, now: number): { [string]: any }
	local record = codec.encode(profile)
	record.lock = lock
	record.savedAt = now
	return record
end

-- Loads and locks a profile (a new one for a first visit). Failure reasons:
-- "error" (the store kept failing), "newerSchema", "corrupt".
function ProfileStore.load(deps: Deps, userId: number): (any, string?)
	local codec = deps.codec
	for attempt = 1, deps.loadAttempts do
		local status = "error"
		local loaded: any = nil
		local steal = attempt == deps.loadAttempts
		local ok, err = pcall(function()
			deps.store:UpdateAsync(ProfileStore.key(userId), function(record: any)
				local now = deps.now()
				loaded = nil
				local profile: any
				if record == nil then
					profile = codec.new()
				else
					local decoded, reason = codec.decode(record)
					if decoded == nil then
						status = reason or "corrupt"
						return nil
					end
					local holder, at = lockHolder(record)
					if holder and holder ~= deps.session and now - at < ProfileStore.LOCK_STALE_SECONDS and not steal then
						status = "busy"
						return nil
					end
					profile = decoded
				end
				status = "ok"
				loaded = profile
				return encode(codec, profile, { session = deps.session, at = now }, now), { userId }
			end)
		end)
		if ok and status == "ok" and loaded then
			return loaded, nil
		elseif ok and (status == "newerSchema" or status == "corrupt") then
			return nil, status
		end
		if not ok then
			deps.log(`[ProfileStore] load {userId} attempt {attempt}: {err}`)
		end
		if attempt < deps.loadAttempts then
			deps.wait(deps.retrySeconds)
		end
	end
	return nil, "error"
end

-- Saves while this session holds the lock; `release` frees it (leaving).
-- Failure reasons: "lockLost", "error".
function ProfileStore.save(deps: Deps, userId: number, profile: any, release: boolean): (boolean, string?)
	local snapshot = deps.codec.encode(profile)
	for attempt = 1, ProfileStore.SAVE_ATTEMPTS do
		local status = "error"
		local ok, err = pcall(function()
			deps.store:UpdateAsync(ProfileStore.key(userId), function(record: any)
				local now = deps.now()
				if lockHolder(record) ~= deps.session then
					status = "lockLost"
					return nil
				end
				status = "ok"
				local out = table.clone(snapshot)
				out.lock = if release then nil else { session = deps.session, at = now }
				out.savedAt = now
				return out, { userId }
			end)
		end)
		if ok and status == "ok" then
			return true, nil
		elseif ok and status == "lockLost" then
			return false, "lockLost"
		end
		deps.log(`[ProfileStore] save {userId} attempt {attempt}: {err}`)
		if attempt < ProfileStore.SAVE_ATTEMPTS then
			deps.wait(deps.retrySeconds)
		end
	end
	return false, "error"
end

-- An in-memory store with the same UpdateAsync shape (tests, and Studio when
-- the place can't reach DataStores).
function ProfileStore.memoryStore(): Store
	local records: { [string]: any } = {}
	local store = {}
	function store.UpdateAsync(_, key: string, transform: (any) -> ...any)
		local current = records[key]
		local copy = if type(current) == "table" then table.clone(current) else current
		local result = transform(copy)
		if result ~= nil then
			records[key] = result
		end
		return result
	end
	return store :: any
end

return ProfileStore
