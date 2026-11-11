--!strict
-- Game-feel moments read from confirmed state (Bruno, 2026-11-08: "Let's do
-- all of them", then "all six"; docs/design/NINTENDO_FEEL_RESEARCH.md).
-- Presentation only.
--
-- "impact": the attack's second beat, after Galaxy's two Star Bit sounds.
-- The press has its own feedback in the HUD; this is the moment your troops
-- first take the target nation's land. A confirmed send toward a nation (the
-- same news as the "Attacking X with N" toast) arms it; the first changed
-- tile of yours beside that nation's land fires it, once, at that tile.
-- Sends to empty land have no second beat. Boats arm when they land and
-- start their attack.
--
-- "loss": the alarm points somewhere. A new attack on you (not a tribe's,
-- as the attacks list) arms its attacker; the first tile it takes beside
-- your land fires a ping there. The land-falling-fast alarm re-arms every
-- attacker (armLosses), so a long war pings again when it turns bad.

local HudModel = require(script.Parent.HudModel)

local FeelCues = {}
FeelCues.__index = FeelCues

-- An armed moment waits this many ticks (5 s) for contact, then lapses.
local ARM_TICKS = 50

export type Moment = { kind: "impact" | "loss", other: number, tile: number }

export type FeelCues = typeof(setmetatable(
	{} :: {
		-- other player's smallID -> tick armed
		armed: { [number]: number },
		armedIn: { [number]: number },
		sent: { [number]: number }?,
		incoming: { [number]: boolean },
	},
	FeelCues
))

function FeelCues.new(): FeelCues
	return setmetatable({ armed = {}, armedIn = {}, sent = nil, incoming = {} }, FeelCues)
end

-- Incoming attacks the attacks list shows: not from tribes.
local function incomingAttacks(state: any): { any }
	local out = {}
	for _, a in state.attacks do
		local p = state.players[a.attacker]
		if not a.outgoing and p ~= nil and p.type ~= "BOT" then
			table.insert(out, a)
		end
	end
	return out
end

-- A fresh match view (snapshot): attacks already under way aren't news.
function FeelCues.reset(self: FeelCues, state: any)
	table.clear(self.armed)
	table.clear(self.armedIn)
	table.clear(self.incoming)
	local _, now = HudModel.sendToasts(state, nil)
	self.sent = now
	for _, a in incomingAttacks(state) do
		self.incoming[a.id] = true
	end
end

local function lapse(state: any, armed: { [number]: number })
	for other, at in armed do
		local p = state.players[other]
		if state.tick - at > ARM_TICKS or p == nil or not p.alive then
			armed[other] = nil
		end
	end
end

-- Once per applied tick: arms new sends toward nations and new attacks on you.
function FeelCues.tick(self: FeelCues, state: any)
	local news, now = HudModel.sendToasts(state, self.sent)
	self.sent = now
	for _, n in news do
		if n.target ~= 0 and n.target ~= state.you and state.players[n.target] ~= nil then
			self.armed[n.target] = state.tick
		end
	end
	local incoming = {}
	for _, a in incomingAttacks(state) do
		incoming[a.id] = true
		if not self.incoming[a.id] then
			self.armedIn[a.attacker] = state.tick
		end
	end
	self.incoming = incoming
	lapse(state, self.armed)
	lapse(state, self.armedIn)
end

-- The land-falling-fast alarm sounded: every current attacker pings again.
function FeelCues.armLosses(self: FeelCues, state: any)
	for _, a in incomingAttacks(state) do
		self.armedIn[a.attacker] = state.tick
	end
end

-- The neighbour of `tile` (4-neighbourhood) owned by a key of `set`, if any.
local function besideAny(state: any, tile: number, set: { [number]: number }): number?
	local w, h = state.width, state.height
	local x, y = tile % w, tile // w
	if x > 0 and set[state:ownerAt(tile - 1)] then
		return state:ownerAt(tile - 1)
	elseif x < w - 1 and set[state:ownerAt(tile + 1)] then
		return state:ownerAt(tile + 1)
	elseif y > 0 and set[state:ownerAt(tile - w)] then
		return state:ownerAt(tile - w)
	elseif y < h - 1 and set[state:ownerAt(tile + w)] then
		return state:ownerAt(tile + w)
	end
	return nil
end

-- Whether `tile` touches the viewer's land.
local function besideMe(state: any, tile: number): boolean
	local w, h, me = state.width, state.height, state.you
	local x, y = tile % w, tile // w
	return (x > 0 and state:ownerAt(tile - 1) == me)
		or (x < w - 1 and state:ownerAt(tile + 1) == me)
		or (y > 0 and state:ownerAt(tile - w) == me)
		or (y < h - 1 and state:ownerAt(tile + w) == me)
end

-- TilesChanged: at most one moment per armed player.
function FeelCues.tiles(self: FeelCues, state: any, changed: { number }): { Moment }
	local out: { Moment } = {}
	local armed, armedIn = self.armed, self.armedIn
	if next(armed) == nil and next(armedIn) == nil then
		return out
	end
	local me = state.you
	for _, tile in changed do
		local owner = state:ownerAt(tile)
		if owner == me and next(armed) ~= nil then
			local hit = besideAny(state, tile, armed)
			if hit then
				armed[hit] = nil
				table.insert(out, { kind = "impact", other = hit, tile = tile })
			end
		elseif armedIn[owner] and besideMe(state, tile) then
			armedIn[owner] = nil
			table.insert(out, { kind = "loss", other = owner, tile = tile })
		end
		if next(armed) == nil and next(armedIn) == nil then
			break
		end
	end
	return out
end

return FeelCues
