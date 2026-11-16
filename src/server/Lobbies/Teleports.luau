--!strict
-- Ported from RoWorld 2be8efb (src/server/Lobbies/Teleports.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- TeleportService for public lobbies: reserve a match server, send players
-- to it, send them back to a hub (a public server of the same place).
-- Teleports can't run in Studio: there `studio()` gives stand-ins (a fake
-- reserved server; `send` reports "studio" so the caller plays the lobby on
-- this server instead).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Teleports = {}

Teleports.RETRIES = 3
-- A return teleport under way for a player is not started again within this
-- long (a LEAVE pressed twice, or the match ending while one is in flight).
Teleports.PENDING_S = 20

-- `send` returns (true, INFLIGHT) when Roblox says the players are already
-- teleporting ("already in progress or throttled", 2026-11-15 review: about
-- 60 a day, mostly a PLAY pressed twice or a retry after a slow first
-- attempt). The same message also covers a throttled teleport, where the
-- player isn't moving, so a caller that has a fallback waits INFLIGHT_WAIT_S
-- and uses it only if the player is still on this server.
Teleports.INFLIGHT = "inflight"
Teleports.INFLIGHT_WAIT_S = 20

function Teleports.isInFlightError(msg: string): boolean
	return string.find(msg, "already in progress", 1, true) ~= nil
end

export type Teleporter = {
	reserve: () -> (string, string),
	send: (players: { Player }, code: string, data: { [string]: any }) -> (boolean, string?),
	toHub: (players: { Player }, data: { [string]: any }?) -> (boolean, string?),
}

function Teleports.live(placeId: number): Teleporter
	local pending: { [Player]: number } = {}
	TeleportService.TeleportInitFailed:Connect(function(player: Player)
		pending[player] = nil
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		pending[player] = nil
	end)

	local function reserve(): (string, string)
		local code, psid = TeleportService:ReserveServer(placeId)
		return code, psid
	end

	local function send(players: { Player }, code: string, data: { [string]: any }): (boolean, string?)
		-- Only players still here, and not already on their way (a teleport
		-- started within PENDING_S that hasn't failed).
		local now = os.clock()
		local list, onTheirWay = {}, 0
		for _, p in players do
			if p.Parent ~= nil then
				if pending[p] ~= nil and now - pending[p] <= Teleports.PENDING_S then
					onTheirWay += 1
				else
					table.insert(list, p)
				end
			end
		end
		if #list == 0 then
			if onTheirWay > 0 then
				return true, Teleports.INFLIGHT
			end
			return false, "The player left."
		end
		local opts = Instance.new("TeleportOptions")
		opts.ReservedServerAccessCode = code
		opts:SetTeleportData(data)
		local last: any = nil
		for attempt = 1, Teleports.RETRIES do
			local ok, err = pcall(function()
				TeleportService:TeleportAsync(placeId, list, opts)
			end)
			if ok then
				for _, p in list do
					pending[p] = os.clock()
				end
				return true, nil
			end
			last = err
			if Teleports.isInFlightError(tostring(err)) then
				-- (they're already moving, or throttled: retrying can't help)
				for _, p in list do
					pending[p] = os.clock()
				end
				return true, Teleports.INFLIGHT
			end
			-- someone may have left while we waited
			for i = #list, 1, -1 do
				if list[i].Parent == nil then
					table.remove(list, i)
				end
			end
			if #list == 0 then
				return false, "The player left."
			end
			task.wait(attempt)
		end
		warn("[Lobbies] teleport failed: " .. tostring(last))
		return false, "The teleport failed. Try again."
	end

	-- `data` (optional) reaches the hub as the teleport data (who was in which party).
	local function toHub(players: { Player }, data: { [string]: any }?): (boolean, string?)
		local now = os.clock()
		local list = {}
		for _, p in players do
			if p.Parent ~= nil and (pending[p] == nil or now - pending[p] > Teleports.PENDING_S) then
				pending[p] = now
				table.insert(list, p)
			end
		end
		if #list == 0 then
			return true, nil -- (all on their way already)
		end
		local ok, err = pcall(function()
			if data ~= nil then
				local opts = Instance.new("TeleportOptions")
				opts:SetTeleportData(data)
				TeleportService:TeleportAsync(placeId, list, opts)
			else
				TeleportService:TeleportAsync(placeId, list)
			end
		end)
		if not ok then
			for _, p in list do
				pending[p] = nil
			end
			local msg = tostring(err)
			if Teleports.isInFlightError(msg) then
				return true, nil
			end
			warn("[Lobbies] return teleport failed: " .. msg)
		end
		return ok, if ok then nil else tostring(err)
	end

	return { reserve = reserve, send = send, toHub = toHub }
end

-- Studio stand-ins.
function Teleports.studio(): Teleporter
	local n = 0
	return {
		reserve = function(): (string, string)
			n += 1
			return "studio-code-" .. n, "studio-psid-" .. n
		end,
		send = function(_players: { Player }, _code: string, _data: { [string]: any }): (boolean, string?)
			return false, "studio"
		end,
		toHub = function(_players: { Player }, _data: { [string]: any }?): (boolean, string?)
			return true, nil
		end,
	}
end

function Teleports.forPlace(placeId: number): Teleporter
	if RunService:IsStudio() then
		return Teleports.studio()
	end
	return Teleports.live(placeId)
end

return Teleports
