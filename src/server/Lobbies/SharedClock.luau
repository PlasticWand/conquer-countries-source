--!strict
-- Ported from RoWorld 2be8efb (src/server/Lobbies/SharedClock.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- A wall clock every server agrees on, for the public lobbies (start times,
-- heartbeats and locks are written by one server and read by others).
-- Roblox servers' own clocks can be minutes apart, so each server measures
-- its offset from Roblox's backend clock: a DataStore write's
-- DataStoreKeyInfo.UpdatedTime is stamped by the backend, and the local time
-- halfway through the call is compared with it (error: half the round trip).
-- Re-measured now and then; offset 0 when DataStores are unavailable (Studio
-- without API access), where there is only one server anyway.
--   SharedClock.start()  measure now and every RESYNC_S
--   SharedClock.now()    os.time() corrected by the offset (seconds, fractional)
--   SharedClock.ready()  measured once, or gave up (scheduling waits for this)

local SharedClock = {}

SharedClock.STORE = "ConquestSharedClock"
SharedClock.KEY = "probe"
-- Each measurement writes one of this many keys at random (one key takes a
-- write every few seconds at most; RoWorld's servers all writing one key
-- were refused).
SharedClock.KEYS = 256
SharedClock.RESYNC_S = 20 * 60
SharedClock.READY_TIMEOUT_S = 15
-- A measurement whose round trip took longer than this is too imprecise.
SharedClock.MAX_RTT_S = 4.0

SharedClock.offset = 0.0
SharedClock.synced = false
SharedClock._startedAt = os.clock()
SharedClock._givenUp = false

local function millis(): number
	return DateTime.now().UnixTimestampMillis
end

-- (From the millisecond clock the offset is measured against: os.time()
-- counts whole seconds, so the waiting room's "seconds left", sent twice a
-- second, came out up to a second high every other time and its countdown
-- went 10, 9, 10, 9, 8... (Bruno's phone, 2026-11-10).)
function SharedClock.now(): number
	return millis() / 1000 + SharedClock.offset
end

function SharedClock.ready(): boolean
	return SharedClock.synced or SharedClock._givenUp or os.clock() - SharedClock._startedAt > SharedClock.READY_TIMEOUT_S
end

-- One measurement (yields). True when the offset was updated.
function SharedClock.measure(log: ((string) -> ())?): boolean
	local okStore, store = pcall(function()
		return game:GetService("DataStoreService"):GetDataStore(SharedClock.STORE)
	end)
	if not okStore then
		return false
	end
	local t0 = millis()
	local ok, info = pcall(function()
		local key = SharedClock.KEY .. tostring(math.random(1, SharedClock.KEYS))
		local _, keyInfo = store:UpdateAsync(key, function(old: any): any
			return (tonumber(old) or 0) + 1
		end)
		return keyInfo
	end)
	local t1 = millis()
	if not ok or info == nil or type((info :: any).UpdatedTime) ~= "number" then
		return false
	end
	local rtt = (t1 - t0) / 1000
	if rtt > SharedClock.MAX_RTT_S then
		return false
	end
	-- the backend stamped the write somewhere inside the call: assume the middle
	SharedClock.offset = (info :: any).UpdatedTime / 1000 - (t0 + t1) / 2000
	SharedClock.synced = true
	if log then
		log(string.format("[SharedClock] offset %+.1fs (rtt %.0fms)", SharedClock.offset, rtt * 1000))
	end
	return true
end

-- Measures now (in the background) and every RESYNC_S. Gives up waiting
-- after three failed first tries.
function SharedClock.start(log: ((string) -> ())?)
	SharedClock._startedAt = os.clock()
	task.spawn(function()
		local tries = 0
		while not SharedClock.measure(log) do
			tries += 1
			if tries >= 3 then
				SharedClock._givenUp = true
				break
			end
			task.wait(2)
		end
		while true do
			task.wait(SharedClock.RESYNC_S)
			SharedClock.measure(log)
		end
	end)
end

return SharedClock
