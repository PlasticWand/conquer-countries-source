--!strict
-- Which sound cue each confirmed match change makes (Bruno's audio brief,
-- 2026-10-30; the cue keys are the sound board's, Ui/OpenFront/SoundPicks).
-- Built on OpenFront's SoundEffectController and AmbienceController, plus
-- the cues Bruno added (sends, land, danger alerts, warship, our weapons).
-- Pure (Lune-tested): the client adapter feeds it ClientState's signals and
-- plays what it returns. Throttles count ticks (10 a second), so a burst of
-- events in one delta still makes one sound.

local AudioCues = {}
AudioCues.__index = AudioCues

-- Structures and boats that sound when they appear (OpenFront: on creation,
-- your own only). Bombs sound for anyone's launch, as in the source.
local OWN_CREATED: { [string]: string } = {
	City = "build.city",
	Port = "build.port",
	["Defense Post"] = "build.defensePost",
	Factory = "build.factory",
	["SAM Launcher"] = "build.sam",
	["Missile Silo"] = "build.silo",
	Warship = "build.warship",
	Transport = "naval.boat",
	Artillery = "build.artillery", -- the Arsenal (ARSENAL_V2)
	Airfield = "build.airfield",
	Railgun = "build.railgun",
	["Coastal Battery"] = "build.coastal",
	["Field Works"] = "build.fieldWorks",
}
-- The Arsenal's strikes: heard by the shooter and by whoever they're aimed at.
local STRIKE_LAUNCH: { [string]: string } = { ["Air Strike"] = "wpn.airStrike", ["Railgun Shot"] = "wpn.railgunFire", Paratroopers = "wpn.paraLaunch" }
local ANY_LAUNCH: { [string]: string } = {
	["Atom Bomb"] = "wpn.atomLaunch",
	["Hydrogen Bomb"] = "wpn.hydrogenLaunch",
	MIRV = "wpn.mirvLaunch",
	["Mega Nuke"] = "wpn.megaLaunch",
	Scattershot = "wpn.scatterLaunch", -- the Arsenal (ARSENAL_V2)
}
local DETONATION: { [string]: string } = {
	["Atom Bomb"] = "wpn.atomHit",
	["Hydrogen Bomb"] = "wpn.hydrogenHit",
	["Mega Nuke"] = "wpn.hydrogenHit",
	Scattershot = "wpn.atomHit",
}
local STRUCTURE: { [string]: boolean } = {
	City = true,
	Port = true,
	["Defense Post"] = true,
	Factory = true,
	["SAM Launcher"] = true,
	["Missile Silo"] = true,
	Artillery = true,
	Airfield = true,
	Railgun = true,
	["Coastal Battery"] = true,
}
local NUKE_INBOUND: { [string]: boolean } = { NUKE_INBOUND = true, HYDROGEN_BOMB_INBOUND = true, MIRV_INBOUND = true }

-- Gaps in ticks. The source's: a MIRV boom at most every 5, the nuke alarm
-- every 10. Ours keep the steady cues soft (Bruno: steady feedback, never
-- spam).
local GAP: { [string]: number } = {
	["wpn.mirvHit"] = 5,
	["alert.nuke"] = 10,
	["alert.losing"] = 80,
	["alert.attacked"] = 60,
	["naval.shell"] = 8,
	["wpn.samShot"] = 5,
	["act.gold"] = 20,
	["dip.emoji"] = 10,
	["wpn.artilleryFire"] = 5,
	["wpn.shellImpact"] = 5,
}
-- "Troops sent" loops while your land grows (Bruno, 2026-10-30, after
-- RoWorld's pop): from your land growing under an attack of yours until it
-- hasn't grown for EXPAND_HOLD ticks.
local EXPAND_HOLD = 5
-- The pops rise in pitch over a run of growth (Bruno, 2026-11-08, after Wii
-- Fit's hoop getting livelier as you succeed): `popRise` goes 0 to 1 over
-- this many ticks of growing land and drops back when the run ends.
local RISE_TICKS = 40
-- Land taken counts from this many tiles a tick; land lost sounds when this
-- share of your land (and at least LOSS_MIN tiles) went in LOSS_WINDOW ticks.
local LAND_STEP = 1
local LOSS_WINDOW = 20
local LOSS_SHARE = 0.02
local LOSS_MIN = 30

-- Ambience (AmbienceController): from 8 pixels a tile, the nearest city,
-- factory, silo or SAM within 20 tiles of the view's centre, fading up to
-- its peak at 20. With no structure near, the sea if the centre is water.
local AMBIENCE_ZOOM = 8
local MAX_ZOOM = 20
local AMBIENCE_RANGE = 20
local AMBIENCE_BY_TYPE: { [string]: string } = {
	City = "amb.city",
	Factory = "amb.factory",
	["Missile Silo"] = "amb.silo",
	["SAM Launcher"] = "amb.sam",
}

type Seen = { type: string, owner: number, active: boolean, level: number, building: boolean }

export type AudioCues = typeof(setmetatable(
	{} :: {
		seen: { [number]: Seen },
		incomingBoats: { [number]: boolean },
		last: { [string]: number },
		inSpawn: boolean,
		wasAlive: boolean,
		ended: boolean,
		tiles: { number },
		grewAt: number?,
		expanding: boolean,
		growStreak: number,
		popRise: number,
		attackers: { [string]: boolean },
		batteries: { [number]: boolean },
		hearAt: ((tile: number) -> boolean)?,
	},
	AudioCues
))

function AudioCues.new(): AudioCues
	return setmetatable({
		seen = {},
		incomingBoats = {},
		last = {},
		inSpawn = true,
		wasAlive = false,
		ended = false,
		tiles = {},
		grewAt = nil,
		expanding = false,
		growStreak = 0,
		popRise = 0,
		attackers = {},
		batteries = {},
		hearAt = nil,
	}, AudioCues)
end

-- Guns that fire on their own, Artillery and Coastal Batteries, are heard
-- only up close (Bruno, 2026-11-09: "so I don't hear them all the time"):
-- the client sets `hearAt` (zoomed in to HEAR_ZOOM px a tile and the gun on
-- screen). Without it (tests, headless) they're always heard.
AudioCues.HEAR_ZOOM = AMBIENCE_ZOOM
local function hears(self: AudioCues, tile: number?): boolean
	local hearAt = self.hearAt
	return hearAt == nil or (tile ~= nil and hearAt(tile))
end

-- A fresh match view (snapshot): what's already there makes no sound.
function AudioCues.reset(self: AudioCues, state: any)
	table.clear(self.seen)
	table.clear(self.incomingBoats)
	table.clear(self.last)
	table.clear(self.tiles)
	table.clear(self.attackers)
	table.clear(self.batteries)
	self.grewAt, self.expanding = nil, false
	self.growStreak, self.popRise = 0, 0
	for id, u in state.units do
		self.seen[id] = { type = u.type, owner = u.owner, active = u.active ~= false, level = u.level or 1, building = u.underConstruction == true }
		if u.type == "Coastal Battery" and u.active ~= false and u.tile then
			self.batteries[u.tile] = true
		end
	end
	self.inSpawn = state:inSpawnPhase()
	local me = state:me()
	self.wasAlive = me ~= nil and me.alive
	self.ended = state.winner ~= nil
	for _, a in state.attacks do
		if not a.outgoing then
			self.attackers[tostring(a.id)] = true
		end
	end
end

-- Adds `key` unless it sounded within its gap.
local function cue(self: AudioCues, out: { string }, key: string, tick: number)
	local gap = GAP[key]
	if gap then
		local at = self.last[key]
		if at and tick - at < gap then
			return
		end
		self.last[key] = tick
	end
	if not table.find(out, key) then
		table.insert(out, key)
	end
end

-- UnitsChanged: units created, upgraded, landed, detonated or destroyed.
function AudioCues.units(self: AudioCues, state: any, changed: { { [string]: any } }, removed: { number }): { string }
	local out: { string } = {}
	local me, tick = state.you, state.tick
	local function ended(id: number, u: { [string]: any }?, seen: Seen)
		-- u is the last record (inactive), or nil when it went without one.
		local t = seen.type
		local reached = u ~= nil and u.reachedTarget == true
		if DETONATION[t] and reached then
			cue(self, out, DETONATION[t], tick)
		elseif t == "MIRV Warhead" and reached then
			cue(self, out, "wpn.mirvHit", tick)
		elseif t == "Warship" and seen.owner == me and not (u and u.markedForDeletion) then
			cue(self, out, "naval.sunk", tick)
		elseif t == "Transport" then
			if seen.owner == me and reached and not (u and u.retreating) then
				cue(self, out, "naval.landed", tick)
			elseif self.incomingBoats[id] and reached then
				cue(self, out, "alert.boat", tick)
			end
			self.incomingBoats[id] = nil
		elseif t == "Sabotage" then
			-- Your fuse burning out on their building.
			if reached and seen.owner == me then
				cue(self, out, "wpn.sabotageDark", tick)
			end
		elseif t == "Paratroopers" then
			-- Landing: yours, or on your land (a shot-down plane is SAM_HIT's).
			if reached and u and (seen.owner == me or (u.targetTile and state:ownerAt(u.targetTile) == me)) then
				cue(self, out, "wpn.paraLand", tick)
			end
		elseif STRIKE_LAUNCH[t] then
			-- A strike landing: yours, or on your land.
			if reached and u and (seen.owner == me or (u.targetTile and state:ownerAt(u.targetTile) == me)) then
				cue(self, out, "wpn.strikeHit", tick)
			end
		elseif t == "Artillery Shell" then
			-- A shell landing on your land.
			if reached and u and u.targetTile and state:ownerAt(u.targetTile) == me then
				cue(self, out, "wpn.shellImpact", tick)
			end
		elseif t == "Defense Post" and not (u and u.markedForDeletion) then
			-- A post blown up that's yours, or one you're attacking.
			local yours = seen.owner == me
			local attacked = false
			for _, a in state.attacks do
				if a.outgoing and a.target == seen.owner then
					attacked = true
				end
			end
			if yours or attacked then
				cue(self, out, "wpn.postDestroyed", tick)
			end
		end
	end
	for _, u in changed do
		if u.type == "Coastal Battery" and u.tile then
			if u.active ~= false then
				self.batteries[u.tile] = true
			else
				self.batteries[u.tile] = nil
			end
		end
		local seen = self.seen[u.id]
		local active = u.active ~= false
		if seen == nil then
			seen = { type = u.type, owner = u.owner, active = active, level = u.level or 1, building = u.underConstruction == true }
			self.seen[u.id] = seen
			if active then
				local own = OWN_CREATED[u.type]
				if own and u.owner == me then
					cue(self, out, own, tick)
				elseif ANY_LAUNCH[u.type] then
					cue(self, out, ANY_LAUNCH[u.type], tick)
				elseif u.type == "SAMMissile" and u.owner == me then
					cue(self, out, "wpn.samShot", tick)
				elseif u.type == "Shell" and (u.owner == me or (u.targetUnitId and state.units[u.targetUnitId] and state.units[u.targetUnitId].owner == me)) then
					-- (A Coastal Battery's shell only up close.)
					local battery = u.sourceTile ~= nil and self.batteries[u.sourceTile] == true
					if not battery or hears(self, u.sourceTile) then
						cue(self, out, "naval.shell", tick)
					end
				elseif u.type == "Artillery Shell" and u.owner == me then
					if hears(self, u.sourceTile or u.tile) then
						cue(self, out, "wpn.artilleryFire", tick)
					end
				elseif u.type == "Sabotage" and u.owner == me then
					cue(self, out, "wpn.sabotageFuse", tick)
				elseif STRIKE_LAUNCH[u.type] and (u.owner == me or (u.targetTile and state:ownerAt(u.targetTile) == me)) then
					cue(self, out, STRIKE_LAUNCH[u.type], tick)
				end
			else
				ended(u.id, u, seen)
			end
		else
			if seen.active and not active then
				ended(u.id, u, seen)
			elseif active and STRUCTURE[u.type] and u.owner == me and (u.level or 1) > seen.level then
				cue(self, out, "build.upgrade", tick)
			elseif active and STRUCTURE[u.type] and u.owner == me and seen.building and not u.underConstruction then
				-- Its own moment when construction ends (Bruno, 2026-11-08).
				cue(self, out, "build.done", tick)
			end
			seen.active, seen.owner, seen.level = active, u.owner, u.level or seen.level
			seen.building = u.underConstruction == true
		end
	end
	for _, id in removed do
		local seen = self.seen[id]
		if seen and seen.active then
			ended(id, nil, seen)
		end
		self.seen[id] = nil
	end
	return out
end

-- Messages: the feed's lines for you (displayMessage, displayIncomingUnit).
function AudioCues.messages(self: AudioCues, state: any, messages: { any }): { string }
	local out: { string } = {}
	local tick = state.tick
	for _, m in messages do
		local kind, key = m.kind, m.key
		if NUKE_INBOUND[kind] then
			cue(self, out, "alert.nuke", tick)
		elseif kind == "NAVAL_INVASION_INBOUND" and m.params and m.params.unitId then
			self.incomingBoats[m.params.unitId] = true
		elseif kind == "PARATROOPERS_INBOUND" then
			cue(self, out, "alert.para", tick)
		elseif kind == "SABOTAGE_INBOUND" then
			cue(self, out, "alert.sabotage", tick)
		elseif kind == "SABOTAGED" then
			cue(self, out, "wpn.sabotageDark", tick)
		elseif kind == "SAM_HIT" then
			cue(self, out, "wpn.intercept", tick)
		elseif kind == "REINFORCEMENTS" then
			cue(self, out, "wpn.reinforce", tick)
		elseif kind == "RENEW_ALLIANCE" then
			cue(self, out, "dip.expiring", tick)
		elseif kind == "CAPTURED_ENEMY_UNIT" then
			cue(self, out, "act.gold", tick)
		elseif key == "events_display.unit_voluntarily_deleted" then
			cue(self, out, "build.delete", tick)
		end
	end
	return out
end

local function playerById(state: any, id: string?): any
	if id == nil then
		return nil
	end
	for _, p in state.players do
		if p.id == id then
			return p
		end
	end
	return nil
end

-- DiplomacyEvents: alliances, emojis, donations, your conquests.
function AudioCues.events(self: AudioCues, state: any, events: { any }): { string }
	local out: { string } = {}
	local me, tick = state.you, state.tick
	local mine = state:me()
	local myId = if mine then mine.id else nil
	for _, e in events do
		local t = e.type
		if t == "AllianceRequest" and e.recipientID == me then
			cue(self, out, "dip.request", tick)
		elseif t == "AllianceRequestReply" and e.request then
			if e.accepted then
				cue(self, out, "dip.accepted", tick)
			elseif e.request.requestorID == me then
				cue(self, out, "dip.declined", tick)
			end
		elseif t == "BrokeAlliance" and (e.traitorID == me or e.betrayedID == me) then
			cue(self, out, "dip.broken", tick)
		elseif t == "Emoji" and e.emoji and e.emoji.senderID ~= me then
			cue(self, out, "dip.emoji", tick)
		elseif t == "DonateEvent" and myId ~= nil and e.recipientId == myId then
			cue(self, out, "dip.donation", tick)
		elseif t == "ConquestEvent" and myId ~= nil and e.conquerorId == myId then
			-- The source: a battle cue for a human, the payout for anyone else;
			-- and the crossed swords over the captured nation (Bruno).
			local conquered = playerById(state, e.conqueredId)
			cue(self, out, if conquered and conquered.type == "HUMAN" then "act.conquerHuman" else "act.conquerBot", tick)
			cue(self, out, "end.flag", tick)
		end
	end
	return out
end

-- Bonus: gold a trade ship or train paid you.
function AudioCues.bonus(self: AudioCues, state: any, bonuses: { any }): { string }
	local out: { string } = {}
	local mine = state:me()
	for _, b in bonuses do
		if mine and b.player == mine.id and (b.gold or 0) > 0 then
			cue(self, out, "act.gold", state.tick)
		end
	end
	return out
end

-- Once per applied tick: the phase, attacks on you, your land. Also sets
-- `expanding` (the "Troops sent" loop).
function AudioCues.tick(self: AudioCues, state: any): { string }
	local out: { string } = {}
	local tick = state.tick
	local inSpawn = state:inSpawnPhase()
	if self.inSpawn and not inSpawn then
		cue(self, out, "act.start", tick)
	end
	self.inSpawn = inSpawn
	local me = state:me()
	if state.winner ~= nil and not self.ended then
		self.ended = true
		local won = me ~= nil and (me.id == state.winner or (me.team ~= nil and me.team == state.winner))
		cue(self, out, if won then "end.victory" else "end.defeat", tick)
	elseif me and self.wasAlive and not me.alive and not self.ended then
		self.ended = true
		cue(self, out, "end.defeat", tick)
	end
	self.wasAlive = me ~= nil and me.alive

	-- A new attack on you; whether one of yours is under way.
	local attackers, sending = {}, false
	for _, a in state.attacks do
		if a.outgoing and a.attacker == state.you then
			sending = sending or not a.retreating
		elseif not a.outgoing then
			local key = tostring(a.id)
			attackers[key] = true
			if not self.attackers[key] then
				cue(self, out, "alert.attacked", tick)
			end
		end
	end
	self.attackers = attackers

	-- Land: growing drives the troops pops; falling fast sounds the alarm.
	if me and me.alive and not inSpawn then
		local history = self.tiles
		local prev = history[#history]
		if prev and me.tiles >= prev + LAND_STEP and sending then
			self.grewAt = tick
			self.growStreak += 1
		end
		table.insert(history, me.tiles)
		if #history > LOSS_WINDOW then
			table.remove(history, 1)
		end
		local peak = 0
		for _, n in history do
			peak = math.max(peak, n)
		end
		local lost = peak - me.tiles
		if lost >= math.max(LOSS_MIN, peak * LOSS_SHARE) then
			cue(self, out, "alert.losing", tick)
		end
	end
	local grew = self.grewAt
	self.expanding = me ~= nil and me.alive and sending and grew ~= nil and tick - grew <= EXPAND_HOLD
	if not self.expanding then
		self.growStreak = 0
	end
	self.popRise = math.min(1, self.growStreak / RISE_TICKS)
	return out
end

-- The ambience track for a view centred on `center` at `scale` pixels a
-- tile, and its gain (0..1 of the track's level). `isWater(tile)` reads the
-- terrain. Nil when nothing should play.
function AudioCues.ambience(state: any, center: number?, scale: number, isWater: (number) -> boolean): (string?, number)
	if center == nil or scale < AMBIENCE_ZOOM then
		return nil, 0
	end
	local gain = math.clamp((scale - AMBIENCE_ZOOM) / (MAX_ZOOM - AMBIENCE_ZOOM), 0, 1)
	local w = state.width
	local cx, cy = center % w, center // w
	local best, bestD = nil, math.huge
	for _, u in state.units do
		local key = AMBIENCE_BY_TYPE[u.type]
		if key and u.active ~= false and u.tile then
			local dx, dy = u.tile % w - cx, u.tile // w - cy
			local d = dx * dx + dy * dy
			if d <= AMBIENCE_RANGE * AMBIENCE_RANGE and d < bestD then
				best, bestD = key, d
			end
		end
	end
	if best then
		return best, gain
	end
	if isWater(center) then
		return "amb.ocean", gain
	end
	return nil, 0
end

return AudioCues
