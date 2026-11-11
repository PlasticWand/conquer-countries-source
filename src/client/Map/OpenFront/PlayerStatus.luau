--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/frame/derive/PlayerStatus.ts;
-- hud/PlayerIcons.ts; view/PlayerView.ts; name/status-icon.vert.glsl),
-- © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by Conquest.
-- Confirmed-view derivation and transient presentation history only.
local Status = {}
Status.__index = Status
local Visual = require(script.Parent.UnitVisuals)
local function includes(list: {number}?, id: number): boolean return list ~= nil and table.find(list, id) ~= nil end

function Status.new(): any return setmetatable({emojis = {}, targets = {}}, Status) end
function Status.clear(self: any) table.clear(self.emojis); table.clear(self.targets) end

-- Emoji carries its authoritative creation tick. TargetPlayer currently has
-- no creation tick, so use the containing confirmed delta's tick, not wall time.
function Status.events(self: any, events: {any}, tick: number)
	for _, event in events do
		if event.type == "Emoji" and type(event.emoji) == "table" then
			local e = event.emoji
			if type(e.senderID) == "number" and type(e.message) == "string" and type(e.createdAt) == "number" then
				local list = self.emojis[e.senderID] or {}; self.emojis[e.senderID] = list
				table.insert(list, {message = e.message, recipientID = e.recipientID, createdAt = e.createdAt})
			end
		elseif event.type == "TargetPlayer" and type(event.playerID) == "number" and type(event.targetID) == "number" then
			local list = self.targets[event.playerID] or {}; self.targets[event.playerID] = list
			list[event.targetID] = if type(event.createdAt) == "number" then event.createdAt else tick
		end
	end
end

-- Source uses own targets + DIRECT allies' and teammates' targets, without
-- embargo overrides or an alliance-graph walk. Re-evaluate on relation changes.
local function friendly(me: any, other: any): boolean
	return me ~= nil and other ~= nil and (me.smallID == other.smallID or includes(me.allies, other.smallID)
		or (me.team ~= nil and me.team == other.team))
end

function Status.compute(self: any, roster: {any}, units: {[number]: any}, tiles: buffer, you: number,
	diplomacy: any, tick: number, config: any): {[number]: any}
	local players, me, leader, maxTiles = {}, nil, -1, 0
	for _, p in roster do
		players[p.smallID] = p
		if p.smallID == you then me = p end
		if p.alive ~= false and (p.tiles or 0) > maxTiles then maxTiles, leader = p.tiles, p.smallID end
	end
	local targets, incoming, alliances, activeNukes, incomingNukes = {}, {}, {}, {}, {}
	local targetDuration = if config then config:targetDuration() else 0
	local emojiDuration = if config then config:emojiMessageDuration() else 0
	for author, list in self.targets do
		for target, createdAt in list do
			if tick - createdAt >= targetDuration then list[target] = nil
			elseif friendly(me, players[author]) then targets[target] = true end
		end
		if next(list) == nil then self.targets[author] = nil end
	end
	for _, a in diplomacy.alliances or {} do alliances[a.other] = a end
	for _, request in diplomacy.incoming or {} do incoming[request.requestor] = true end
	for _, u in units do
		if u.active ~= false and Visual.isNuke(u.type) then
			activeNukes[u.owner] = true
			local tile = u.targetTile
			if you > 0 and type(tile) == "number" and tile >= 0 and (tile + 1) * 2 <= buffer.len(tiles)
				and bit32.band(buffer.readu16(tiles, tile * 2), 4095) == you then incomingNukes[u.owner] = true end
		end
	end
	local emojiByPlayer = {}
	for sender, list in self.emojis do
		local live, newest = {}, nil
		for _, e in list do
			if tick - e.createdAt < emojiDuration then
				table.insert(live, e)
				-- PlayerIcons visibility: broadcasts or incoming private emoji.
				-- A delivered sender echo is not permission to show private sends
				-- to another recipient. Stable first-arrival ties match the source.
				if (e.recipientID == "AllPlayers" or e.recipientID == you)
					and (newest == nil or e.createdAt > newest.createdAt) then newest = e end
			end
		end
		if #live == 0 then self.emojis[sender] = nil else self.emojis[sender] = live end
		if newest then emojiByPlayer[sender] = newest.message end
	end
	local result = {}
	for _, p in roster do if p.alive ~= false then
		local sid = p.smallID
		local relative = me ~= nil and sid ~= you
		local allied = relative and includes(me.allies, sid)
		local remaining, fraction = 0, 0
		local alliance = alliances[sid]
		if allied and alliance and config then
			remaining = math.max(0, alliance.expiresAt - tick)
			fraction = math.clamp(remaining / math.max(1, config:allianceDuration()), 0, 1)
		end
		result[sid] = {crown = sid == leader, traitor = p.traitor == true, disconnected = p.disconnected == true,
			alliance = allied, allianceReq = relative and incoming[sid] == true,
			target = relative and targets[sid] == true,
			embargo = relative and (includes(me.embargoes, sid) or includes(p.embargoes, you)),
			nukeActive = activeNukes[sid] == true, nukeTargetsMe = incomingNukes[sid] == true,
			traitorRemainingTicks = if p.traitorUntil then math.max(0, p.traitorUntil - tick) else 0,
			allianceFraction = fraction, allianceRemainingTicks = remaining, emoji = emojiByPlayer[sid]}
	end end
	return result
end

-- Original: status-icon.vert slot order, and shared emoji/status row layout.
function Status.icons(data: any): {number}
	local out = {}
	for slot, key in {"crown", "traitor", "disconnected", "alliance", "allianceReq", "target", "embargo", "nukeActive"} do
		if data[key] then table.insert(out, if slot == 8 and not data.nukeTargetsMe then 8 else slot - 1) end
	end
	return out
end

function Status.layout(worldScale: number, zoom: number, count: number): {size: number, x: number, y: number, step: number}
	local size = 36 * worldScale * zoom * 1.1
	return {size = size, x = -(count * size + math.max(0, count - 1) * size * .15) / 2,
		y = -36 * worldScale * zoom * 1.4, step = size * 1.15}
end

-- Original: traitor/alliance expiry flash. This is opacity, not a fabricated
-- countdown label. Missing confirmed traitor expiry leaves the icon steady.
function Status.flash(remainingTicks: number, windowTicks: number, now: number): number
	local window, remaining = windowTicks / 10, remainingTicks / 10
	if window <= 0 or remaining <= 0 or remaining > window then return 1 end
	local elapsed = window - remaining
	local phase = now * 2 + elapsed * elapsed * (1.5 / window)
	return .3 + .7 * (.5 + .5 * math.cos(phase * 6.2832))
end

return Status
