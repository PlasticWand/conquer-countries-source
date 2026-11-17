--!strict
-- Ported from RoWorld 2be8efb (src/client/UI/TitleScreen.luau, the queue card), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- What the waiting room says (Bruno, 2026-11-04). JOIN teleports the player to
-- the lobby's own match server, as RoWorld does; there, instead of the main
-- menu, they see the match they joined: its map, "Match starts in 0:12", who
-- is here, and LEAVE. After the match the same screen says it is taking them
-- back to the lobby while the return teleport runs.
--
--   room (from the server's Menu payload, OpenFrontServer.roomView):
--     mapName, mode ("4 teams", nil for free for all), players, capacity,
--     seconds (until the start, when sent), names (the humans here),
--     starting (the match is about to begin: LEAVE is closed)
--   `elapsed`: seconds since that payload arrived (the countdown runs between
--   pushes). A nil room: just arrived, nothing heard yet.
-- Pure, so Lune tests it; Screens/WaitingRoom lays it out.

local WaitingRoom = {}

-- LEAVE closes this many seconds before the start (Bruno tapped LEAVE at 0:00
-- as the map began loading and was sent back to a hub, 2026-11-04).
WaitingRoom.LEAVE_LOCK_S = 3
-- Names listed before "+N more".
WaitingRoom.NAMES_SHOWN = 8
-- Returning: after this long without a teleport, BACK TO LOBBY asks again.
WaitingRoom.RETRY_AFTER_S = 20

export type Room = {
	mapName: string?,
	mode: string?,
	minutes: number?, -- a timed match (Blitz)
	players: number?,
	capacity: number?,
	seconds: number?,
	names: { string }?,
	starting: boolean?,
}

export type View = {
	kicker: string, -- "PUBLIC MATCH", "TEAM GAME · 4 TEAMS", "MATCH OVER"
	title: string, -- the map, upper case
	status: string, -- the line above the clock
	clock: string?, -- "0:12"
	count: string, -- "3 / 20 players"
	names: string, -- "Paxel, Ada and Bea"
	note: string, -- the small print at the bottom
	leave: boolean, -- LEAVE is offered
	retry: boolean, -- BACK TO LOBBY is offered (returning, stuck)
}

local function clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function nameList(names: { string }): string
	local n = #names
	if n == 0 then
		return ""
	end
	local shown = {}
	for i = 1, math.min(n, WaitingRoom.NAMES_SHOWN) do
		table.insert(shown, names[i])
	end
	if n > WaitingRoom.NAMES_SHOWN then
		return table.concat(shown, ", ") .. ` +{n - WaitingRoom.NAMES_SHOWN} more`
	elseif n == 1 then
		return shown[1]
	end
	local last = table.remove(shown) :: string
	return table.concat(shown, ", ") .. " and " .. last
end

-- The waiting room before the match.
-- The countdown never steps back up for a small correction: the server's
-- "seconds" arrive twice a second with network jitter, and a later one a
-- little above what the last one now predicts (`predicted`, after the local
-- count) would show the clock going back up a second. A big change (the start
-- moved) is taken as it is.
WaitingRoom.SMOOTH_S = 1.5
function WaitingRoom.smooth(predicted: number?, seconds: number?): number?
	if predicted == nil or seconds == nil then
		return seconds
	end
	if seconds > predicted and seconds - predicted < WaitingRoom.SMOOTH_S then
		return predicted
	end
	return seconds
end

function WaitingRoom.view(room: Room?, elapsed: number): View
	if room == nil or room.mapName == nil then
		return {
			kicker = "PUBLIC MATCH",
			title = "",
			status = "Getting the match ready…",
			clock = nil,
			count = "",
			names = "",
			note = "Empty seats are filled with nations.",
			leave = true,
			retry = false,
		}
	end
	local r = room :: Room
	local left = if r.seconds then math.max(0, r.seconds - elapsed) else nil
	local starting = r.starting == true or (left ~= nil and left <= WaitingRoom.LEAVE_LOCK_S)
	local players = r.players or 0
	return {
		kicker = if r.mode then "TEAM GAME  ·  " .. string.upper(r.mode) elseif r.minutes then `BLITZ  ·  {r.minutes} MIN  ·  MOST LAND WINS` else "PUBLIC MATCH",
		title = string.upper(r.mapName :: string),
		status = if starting then "Starting…" elseif left then "Match starts in" else "Getting the match ready…",
		clock = if left and not (r.starting == true and left <= 0) then clock(left) else nil,
		count = if r.capacity then `{players} / {r.capacity} players` else `{players} players`,
		names = nameList(r.names or {}),
		note = "Empty seats are filled with nations.",
		leave = not starting,
		retry = false,
	}
end

-- After the match (or LEAVE): the return teleport is under way. `elapsed`:
-- seconds since it began; past RETRY_AFTER_S, BACK TO LOBBY asks again.
function WaitingRoom.returning(elapsed: number): View
	return {
		kicker = "MATCH OVER",
		title = "BACK TO THE LOBBY",
		status = "Taking you back to the lobby…",
		clock = nil,
		count = "",
		names = "",
		note = "Fork of OpenFront  ·  © OpenFront and Contributors",
		leave = false,
		retry = elapsed >= WaitingRoom.RETRY_AFTER_S,
	}
end

-- The server tells clients which kind it is with this attribute on
-- ReplicatedStorage (Roblox doesn't give clients game.PrivateServerId).
WaitingRoom.ROLE_ATTRIBUTE = "ConquestServerRole"
WaitingRoom.ROLE_MATCH = "match"
WaitingRoom.ROLE_HUB = "hub"
-- One player's solo match on a reserved server of its own (audit F3).
WaitingRoom.ROLE_SOLO = "solo"

-- Whether this server is a public match's own (a reserved server, not a
-- player's private one). `privateServerId`, `ownerId`: game's, on the server.
function WaitingRoom.isMatchServer(privateServerId: string, ownerId: number): boolean
	return privateServerId ~= "" and ownerId == 0
end

return WaitingRoom
