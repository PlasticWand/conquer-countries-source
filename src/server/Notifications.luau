--!strict
-- Experience notifications (2026-11-15 review, Bruno: "Do them all"): a
-- "come back" notification about a day after a player leaves. Players opt in
-- through Roblox's own prompt after their first match (Shared/EngagePrompts);
-- Roblox delivers only to those who did, at most one a day per experience.
--
-- How it works: a player leaving is scheduled in a MemoryStore sorted map
-- (sort key: when it's due); joining again cancels it. Every server checks
-- once a minute for due entries, claims each one atomically (so only one
-- server sends it) and calls Open Cloud's user-notifications API.
--
-- Off until both are set up (Bruno's steps, docs/STATUS.md 2026-11-15):
--   MESSAGE_ID  the notification string's asset id (Creator Hub, Engagement,
--               Notifications);
--   SECRET      an Open Cloud API key with user notifications write for this
--               experience, stored in Creator Hub Secrets under this name
--               (domain apis.roblox.com), and HTTP requests enabled.
-- Never in Studio.

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Notifications = {}

-- The notification string's asset id ("" = off): "New flags are in today's
-- shop. Come back and conquer the world!" (created 2026-11-15).
Notifications.MESSAGE_ID = "74bb1a53-c445-954f-9da7-2b12346fb976"
Notifications.SECRET = "notify_api_key"
Notifications.MAP = "conquest_notify_v1"
Notifications.DELAY_S = 20 * 3600
Notifications.KEEP_S = 3 * 24 * 3600 -- an entry lapses this long after it's due
Notifications.POLL_S = 60
Notifications.BATCH = 20

local map: any = nil
local secret: any = nil

local function schedule(userId: number)
	local due = os.time() + Notifications.DELAY_S
	pcall(function()
		map:SetAsync(tostring(userId), due, Notifications.DELAY_S + Notifications.KEEP_S, due)
	end)
end

local function cancel(userId: number)
	pcall(function()
		map:RemoveAsync(tostring(userId))
	end)
end

local function send(userId: number): boolean
	local body = HttpService:JSONEncode({
		source = { universe = `universes/{game.GameId}` },
		payload = {
			message_id = Notifications.MESSAGE_ID,
			type = "MOMENT",
			join_experience = { launch_data = "notify:comeback" },
			analytics_data = { category = "Comeback" },
		},
	})
	local ok, res = pcall(function(): any
		return HttpService:RequestAsync({
			Url = `https://apis.roblox.com/cloud/v2/users/{userId}/notifications`,
			Method = "POST",
			Headers = { ["x-api-key"] = secret, ["Content-Type"] = "application/json" } :: any,
			Body = body,
		})
	end)
	if not ok then
		warn(`[Notifications] request failed: {res}`)
		return false
	end
	-- (429: over Roblox's daily limit for them; 4xx otherwise: not opted in
	-- or not eligible. Neither is retried.)
	return res.Success == true
end

-- One pass: claim the due entries and send them.
local function poll()
	local now = os.time()
	local ok, items = pcall(function(): any
		return map:GetRangeAsync(Enum.SortDirection.Ascending, Notifications.BATCH, nil, { sortKey = now })
	end)
	if not ok or type(items) ~= "table" then
		return
	end
	local token = `{game.JobId}:{now}`
	for _, item in items do
		local userId = tonumber(item.key)
		if userId and Players:GetPlayerByUserId(userId) == nil then
			-- Claim it: only the server whose token lands sends it. The claim
			-- moves it far out of the due range and lapses in a day.
			local claimed = false
			pcall(function()
				local final = map:UpdateAsync(item.key, function(value: any, _sortKey: any): (any, any)
					if type(value) ~= "number" or value > now then
						return nil
					end
					return token, now + 1e9
				end, 24 * 3600)
				claimed = final == token
			end)
			if claimed then
				send(userId)
			end
		end
	end
end

function Notifications.start()
	if RunService:IsStudio() or Notifications.MESSAGE_ID == "" then
		return
	end
	local ok = pcall(function()
		secret = HttpService:GetSecret(Notifications.SECRET)
		map = MemoryStoreService:GetSortedMap(Notifications.MAP)
	end)
	if not ok or secret == nil or map == nil then
		-- (not set up yet: quietly off, so the error report stays clean)
		return
	end
	Players.PlayerAdded:Connect(function(player: Player)
		cancel(player.UserId)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		schedule(player.UserId)
	end)
	task.spawn(function()
		-- (servers start at different times, so they rarely poll together)
		task.wait(math.random() * Notifications.POLL_S)
		while true do
			poll()
			task.wait(Notifications.POLL_S)
		end
	end)
end

return Notifications
