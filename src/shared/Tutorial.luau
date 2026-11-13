--!strict
-- Ported from RoWorld 2be8efb (src/shared/Data/Tutorial.luau, src/client/UI/Tutorial.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- A new player's first match (Bruno, 2026-11-10: port RoWorld's tutorial and
-- keep its rookie protections). RoWorld built it phones first from its own
-- onboarding funnel (202,158 new players over 28 days):
--
--   Joined 100% -> Match started 85% -> Spawned 81% -> First attack 66%
--   -> Survived 3 min 32% -> Survived 10 min 24% -> Second match 21%
--
--   * 14% never started a match: the first match starts by itself;
--   * 5% never picked a start: a spot is marked, and taken for them after
--     AUTO_SPAWN_S;
--   * 19% spawned and never attacked: the first step is the first tap, its
--     place marked;
--   * half of those who attacked were gone within 3 minutes, with nothing to
--     do yet: so the first minutes are small goals with a reward at the end,
--     on a match with fewer tribes in the way and the gentlest AI.
--
-- The match is an ordinary solo match otherwise and goes on after the last
-- step. This module is pure (Lune-tested): the numbers, and `Tutorial.newRun`,
-- the steps as a state machine that the client's TutorialController feeds
-- with what it sees each frame and draws from what it returns.
--
-- Rookie protections (Conquest differences from OpenFront, client-side: they
-- only trim the share an order asks for, as RoWorld's UICtx.send does):
--   * while the tutorial runs the Attack bar stops at RATIO_CAP and every
--     order keeps TROOP_FLOOR of the troop limit at home;
--   * in a player's first ROOKIE_MATCHES matches every order keeps
--     ROOKIE_FLOOR of the troop limit at home.

local Tutorial = {}

-- Stars for finishing it, once per player (RoWorld's amount).
Tutorial.STARS = 1000
-- The tutorial's match (OpenFrontServer.soloConfig): World, OpenFront's
-- Easy nations, BOTS tribes instead of 400, and a 1 s deploy countdown
-- (RoWorld, 2026-10-04: a 5 s wait after placing the capital confused new
-- players).
Tutorial.MAP = "World"
Tutorial.DIFFICULTY = "Easy"
Tutorial.BOTS = 60
Tutorial.COUNTDOWN_S = 1

-- The Attack bar's stops (OfHud's chips) and where a match starts.
Tutorial.RATIO_STOPS = { 0.1, 0.2, 0.35, 0.5, 0.75 }
Tutorial.DEFAULT_RATIO = 0.2
-- The bar stops here while the tutorial runs (RoWorld: a saved 85% sent too much).
Tutorial.RATIO_CAP = 0.5

-- While the tutorial runs an order leaves TROOP_FLOOR of the troop limit at
-- home (trimmed to what may go, not sent when nothing may). The floor holds
-- from the FLOOR_FROM step, once the army reaches FLOOR_ARM of its limit or
-- the nation has been in play FLOOR_ARM_S seconds (RoWorld 2026-10-27: a new
-- nation starts at about a fifth of its limit, so arming on troops alone
-- never armed for the players it is for; and before the first neighbour it
-- refused the very taps the card asked for).
Tutorial.TROOP_FLOOR = 0.25
Tutorial.FLOOR_ARM = 0.35
Tutorial.FLOOR_ARM_S = 10
Tutorial.FLOOR_FROM = "attack"
Tutorial.FLOOR_REASON = "Troops low. Let them grow back"
-- A new player's first ROOKIE_MATCHES matches (the tutorial's among them)
-- keep ROOKIE_FLOOR at home after the tutorial too (RoWorld: an army spent
-- below a fifth of its limit all but loses, and 23% of its matches ended in
-- their first 3 minutes).
Tutorial.ROOKIE_MATCHES = 5
Tutorial.ROOKIE_FLOOR = 0.2

-- Seconds on the spawn step before the marked spot is taken for the player.
Tutorial.AUTO_SPAWN_S = 12
-- "grow": one expansion, after the troops refill to GROW_READY of the limit.
-- The wait is advice, never a gate (RoWorld: a gate it couldn't pass cut the
-- step's finishers from 88% to 79%): one sent early counts, and its green card
-- says to let the bar fill next time for EARLY_S.
Tutorial.GROW_TAPS = 1
Tutorial.GROW_READY = 0.3
Tutorial.EARLY_S = 2.0
-- "attack" is passed over when nobody borders the player this long.
Tutorial.CONTACT_WAIT_S = 25
-- "ratio": one tap on the 35% stop, held RATIO_HOLD_S. Never a push to send
-- everything; above RATIO_HIGH the card says to come back down. (RoWorld: a
-- precise slider target lost 19.4% of the players on this step.)
Tutorial.RATIO_GOAL = 0.35
Tutorial.RATIO_LOW = 0.3
Tutorial.RATIO_HIGH = 0.4
Tutorial.RATIO_HOLD_S = 0.2
Tutorial.RATIO_MAX_S = 30
Tutorial.RATIO_TOO_MUCH = "Too many! Tap 35%"
-- A step nobody finishes in this long is passed over (nobody is ever stuck).
Tutorial.STEP_MAX_S = 75
-- With no order for this long the mark shows where to tap again.
Tutorial.NUDGE_S = 5
-- A finished step's green card stands this long; the reward card this long.
Tutorial.DONE_S = 0.9
Tutorial.END_S = 9.0

export type Step = {
	id: string,
	touch: string,
	desktop: string,
	wait: string?,
	early: string?,
	bar: boolean?,
	maxS: number?,
}

-- The steps, in order. `%s` is the neighbour's name.
Tutorial.STEPS = {
	{ id = "spawn", touch = "Tap the map to place your capital", desktop = "Click the map to place your capital" },
	{ id = "expand", touch = "Tap the land next to you to take it", desktop = "Click the land next to you to take it" },
	{
		id = "grow",
		touch = "Tap empty land to expand",
		desktop = "Click empty land to expand",
		wait = "Now let your troops refill",
		early = "Done! Next time, let the bar fill",
		bar = true,
	},
	-- (the neighbour before the Attack bar: a first attack at 20% keeps an army
	-- at home; in RoWorld's first order of steps players sent everything)
	{ id = "attack", touch = "Tap %s, then press ATTACK", desktop = "Click %s, then press ATTACK" },
	{
		id = "ratio",
		touch = "Tap 35% below. Keep troops home!",
		desktop = "Click 35% on the Attack bar. Keep troops home!",
		maxS = Tutorial.RATIO_MAX_S,
	},
	{ id = "city", touch = "Tap BUILD, pick City, tap your land", desktop = "Pick City (1) and click your land" },
} :: { Step }

Tutorial.CONTACT_WAIT_LINE = "Keep growing until you meet a neighbour"

-- The "Tutorial" funnel's steps (Creator Dashboard): 1 is the match starting,
-- then one a step, then finishing. A step passed over (stuck, or nobody to
-- attack) is logged too, with a TutorialPassedOver event (2026-11-12).
Tutorial.FUNNEL = { "Started", "Spawned", "First Tap", "Grew", "Attacked", "Used Slider", "Built City", "Completed" }

-- Saved tutorial states (Profile.tutorial).
Tutorial.STATES = { started = true, done = true, skipped = true, left = true }

function Tutorial.stepIndex(id: string): number?
	for i, s in Tutorial.STEPS do
		if s.id == id then
			return i
		end
	end
	return nil
end

-- The funnel step for finishing step `id`.
function Tutorial.funnelStep(id: string): number?
	local i = Tutorial.stepIndex(id)
	return if i then i + 1 else nil
end

-- A player who has never played: no tutorial state, no match counted, no tip
-- seen. `view` is Store/Profile's view.
function Tutorial.isNew(view: any): boolean
	if type(view) ~= "table" then
		return false
	end
	if type(view.tutorial) == "string" and view.tutorial ~= "" then
		return false
	end
	if (tonumber(view.matches) or 0) > 0 then
		return false
	end
	if type(view.tipsSeen) == "table" and #view.tipsSeen > 0 then
		return false
	end
	return true
end

-- Still a new player with `matchesBefore` matches played.
function Tutorial.rookie(matchesBefore: number): boolean
	return matchesBefore < Tutorial.ROOKIE_MATCHES
end

-- The floor under the army holds once it has `troops` of its `cap` at
-- FLOOR_ARM or more, or the nation has been in play `playedS` seconds.
function Tutorial.floorArmed(troops: number, cap: number, playedS: number): boolean
	return playedS >= Tutorial.FLOOR_ARM_S or (cap > 0 and troops >= Tutorial.FLOOR_ARM * cap)
end

-- The most of the army an order may send under `floor` (a share of the troop
-- limit that stays home; nil: no floor, 1). Under 2% counts as nothing.
function Tutorial.floorShare(troops: number, cap: number, floor: number?): number
	if floor == nil or cap <= 0 or troops <= 0 then
		return 1
	end
	local allowed = (troops - floor * cap) / troops
	return if allowed < 0.02 then 0 else math.min(allowed, 1)
end

-- The stop nearest `r` among those not above `max` (the lowest when none is).
function Tutorial.ratioStop(r: number, max: number?): number
	local top = (max or 1) + 1e-6
	local best, bestD = Tutorial.RATIO_STOPS[1], math.huge
	for _, s in Tutorial.RATIO_STOPS do
		if s <= top then
			local d = math.abs(s - r)
			if d < bestD - 1e-9 then
				best, bestD = s, d
			end
		end
	end
	return best
end

-- "grow"'s bar while the army refills: how far `troops` are towards
-- GROW_READY of `cap`, never below `shown` (the limit climbs as the land comes
-- in, and a bar sliding back while nobody did anything reads as broken).
function Tutorial.refill(troops: number, cap: number, shown: number?): number
	local need = Tutorial.GROW_READY * cap
	local f = if need > 0 then math.clamp(troops / need, 0, 1) else 1
	return math.max(f, shown or 0)
end

-- The run ---------------------------------------------------------------------------------

-- What the controller sees each frame.
export type Observation = {
	touch: boolean,
	spawned: boolean, -- your capital is placed
	alive: boolean,
	playing: boolean, -- the spawn phase is over and the match runs
	over: boolean, -- won, lost or left
	-- Orders sent since the last frame: any, on someone's land, on empty land.
	ordered: boolean,
	orderedOwner: boolean,
	orderedLand: boolean,
	troops: number,
	maxTroops: number,
	ratio: number,
	aliveSeconds: number,
	hasSpot: boolean, -- the spawn step's marked spot (the controller finds it)
	spotFree: boolean,
	neighbour: number?, -- a player who borders you (smallID), alive
	neighbourName: string?,
	cityBuilt: boolean,
	placingCity: boolean, -- City chosen in the build bar
	confirmOpen: boolean, -- the build confirmation's ✓ is up
}

-- What to draw. `mark.target`: "spot" | "frontier" | "troops" | "ratio" |
-- "neighbour" | "city" | "ownLand" | "confirm" | nil.
export type Frame = {
	card: { visible: boolean, count: string, text: string, bar: number?, tint: string, skip: string },
	mark: { target: string?, word: string? },
	events: { { [string]: any } },
	troopFloor: number?,
	ratioCap: number,
}

function Tutorial.newRun()
	local run = {
		active = false,
		i = 0,
		t = 0,
		stepT = 0,
		flash = 0,
		ending = 0,
		idle = 0,
		started = false,
		picked = false,
		goldAsked = false,
		shown = nil :: number?,
		taps = 0,
		ready = nil :: boolean?,
		refillF = nil :: number?,
		ratioOk = 0,
		ratioHigh = false,
		neighbour = nil :: number?,
		neighbourName = nil :: string?,
		troopFloor = nil :: number?,
		card = { visible = false, count = "", text = "", bar = nil :: number?, tint = "amber", skip = "Skip" },
	}

	local self: any = run
	local events: { { [string]: any } } = {}

	local function emit(e: { [string]: any })
		table.insert(events, e)
	end

	local function say(touch: boolean)
		local step = Tutorial.STEPS[self.i]
		local txt = if touch then step.touch else step.desktop
		if string.find(txt, "%s", 1, true) then
			txt = string.format(txt, self.neighbourName or "them")
		end
		self.card = { visible = self.i > 1, count = `{self.i} / {#Tutorial.STEPS}`, text = txt, bar = if step.bar then 0 else nil, tint = "amber", skip = "Skip" }
		if self.i > 1 then
			emit({ kind = "pop" })
		end
	end

	function run.begin()
		self.active = true
		self.i = 1
		self.stepT, self.flash, self.ending, self.idle = 0, 0, 0, 0
		self.started, self.picked, self.goldAsked = false, false, false
		self.shown = nil
		self.neighbour, self.neighbourName = nil, nil
		self.troopFloor = nil
		self.card = { visible = false, count = "", text = "", bar = nil, tint = "amber", skip = "Skip" }
	end

	-- "done" | "skipped" | "left"
	function run.stop(how: string)
		if not self.active then
			return
		end
		self.active = false
		self.troopFloor = nil
		if how == "done" then
			self.ending = Tutorial.END_S
			self.card = { visible = true, count = "★", text = `Tutorial complete! +{Tutorial.STARS} stars\nSpend them in the ARSENAL`, bar = nil, tint = "green", skip = "OK" }
			emit({ kind = "sound", key = "menu.stars" })
		else
			self.card = { visible = false, count = "", text = "", bar = nil, tint = "amber", skip = "Skip" }
		end
		emit({ kind = "finished", how = how })
		if how ~= "done" then
			emit({ kind = "closed" })
		end
	end

	-- The reward card's OK, or Skip on a step.
	function run.press()
		if self.ending > 0 then
			self.ending = 0
			self.card.visible = false
			emit({ kind = "closed" })
		else
			run.stop("skipped")
		end
	end

	local function advance(passed: boolean?, touch: boolean)
		local step = Tutorial.STEPS[self.i]
		-- A step passed over is still logged, marked `passed`, so the funnel's
		-- drops are players leaving, not steps nobody could do (2026-11-12).
		local n = Tutorial.funnelStep(step.id) :: number
		emit({ kind = "step", n = n, name = Tutorial.FUNNEL[n], passed = if passed then true else nil })
		if not passed then
			emit({ kind = "sound", key = "ui.confirm" })
			if self.card.visible then
				self.card = { visible = true, count = self.card.count, text = "Nice!", bar = nil, tint = "green", skip = "Skip" }
				self.flash = Tutorial.DONE_S
			end
		end
		self.i += 1
		self.stepT, self.idle = 0, 0
		self.shown = nil
		if self.i > #Tutorial.STEPS then
			emit({ kind = "step", n = #Tutorial.FUNNEL, name = Tutorial.FUNNEL[#Tutorial.FUNNEL] })
			run.stop("done")
		end
	end

	local function frame(target: string?, word: string?): Frame
		local out = {
			card = table.clone(self.card),
			mark = { target = target, word = word },
			events = events,
			troopFloor = self.troopFloor,
			ratioCap = if self.active then Tutorial.RATIO_CAP else 1,
		}
		events = {}
		return out
	end

	function run.update(o: Observation, dt: number): Frame
		self.t += dt
		if self.ending > 0 then
			self.ending -= dt
			if self.ending <= 0 then
				self.card.visible = false
				emit({ kind = "closed" })
			end
			return frame(nil)
		end
		if not self.active then
			return frame(nil)
		end
		if o.over then
			run.stop("left")
			return frame(nil)
		end
		if self.flash > 0 then
			self.flash -= dt
			if self.flash > 0 then
				return frame(nil)
			end
		end
		local i = self.i
		local step = Tutorial.STEPS[i]
		self.stepT += dt
		if self.troopFloor == nil and i >= (Tutorial.stepIndex(Tutorial.FLOOR_FROM) or 1) and Tutorial.floorArmed(o.troops, o.maxTroops, o.aliveSeconds) then
			self.troopFloor = Tutorial.TROOP_FLOOR
		end
		if not self.started and self.stepT > 1 then
			-- the match is up
			self.started = true
			emit({ kind = "step", n = 1, name = Tutorial.FUNNEL[1] })
		end
		local any = o.ordered
		self.idle = if any then 0 else self.idle + dt
		local target: string?, word: string? = nil, nil
		local id = step.id
		if id == "spawn" then
			if o.spawned then
				advance(false, o.touch)
				return frame(nil)
			end
			if o.hasSpot then
				target = "spot"
				if self.stepT > Tutorial.AUTO_SPAWN_S and not self.picked and o.spotFree then
					-- nobody picked: this spot is theirs
					self.picked = true
					emit({ kind = "spawn" })
				end
			end
			return frame(target)
		end
		if o.spawned and not o.alive then
			run.stop("left") -- conquered: the result card takes over
			return frame(nil)
		end
		if not o.playing then
			return frame(nil)
		end
		if self.shown ~= i then
			self.shown = i
			if id == "grow" then
				self.taps, self.ready, self.refillF = 0, nil, nil
				-- (an order sent while "expand"'s card was green was that step's tap)
				any = false
			elseif id == "attack" then
				self.neighbour, self.neighbourName = nil, nil
			elseif id == "ratio" then
				self.ratioOk, self.ratioHigh = 0, false
			elseif id == "city" and not self.goldAsked then
				-- the server tops gold up to a City's price (once)
				self.goldAsked = true
				emit({ kind = "cityGold" })
			end
			say(o.touch)
		end
		if id == "expand" then
			if any then
				advance(false, o.touch)
				return frame(nil)
			end
			target = "frontier"
		elseif id == "grow" then
			if any then
				local early = not self.ready
				self.taps += 1
				if early then
					self.refillF = nil -- (it spent the refill: the bar drops)
				end
				if self.taps >= Tutorial.GROW_TAPS then
					advance(false, o.touch)
					if early and self.card.visible then
						self.card.text = step.early :: string
						self.flash = Tutorial.EARLY_S
					end
					return frame(nil)
				end
			end
			local f = if o.maxTroops > 0 then Tutorial.refill(o.troops, o.maxTroops, self.refillF) else 1
			self.refillF = f
			local ready = f >= 1
			if ready ~= self.ready then
				if ready and self.ready == false then
					emit({ kind = "sound", key = "ui.tick" })
					emit({ kind = "pop" })
				end
				self.ready = ready
			end
			self.card.text = if ready then (if o.touch then step.touch else step.desktop) else step.wait :: string
			self.card.bar = f
			self.card.tint = if ready then "green" else "amber"
			if not ready then
				target, word = "troops", "Refilling"
			elseif self.taps == 0 or self.idle > Tutorial.NUDGE_S then
				target = "frontier"
			end
		elseif id == "ratio" then
			local r = o.ratio
			if r >= Tutorial.RATIO_LOW and r <= Tutorial.RATIO_HIGH then
				self.ratioOk += dt
				if self.ratioOk >= Tutorial.RATIO_HOLD_S then
					advance(false, o.touch)
					return frame(nil)
				end
			else
				self.ratioOk = 0
			end
			local high = r > Tutorial.RATIO_HIGH
			if high ~= self.ratioHigh then
				self.ratioHigh = high
				self.card.text = if high then Tutorial.RATIO_TOO_MUCH elseif o.touch then step.touch else step.desktop
				self.card.tint = if high then "red" else "amber"
			end
			target = "ratio"
		elseif id == "attack" then
			if o.orderedOwner then
				advance(false, o.touch)
				return frame(nil)
			end
			if self.neighbour == nil or self.neighbour ~= o.neighbour then
				if o.neighbour ~= nil then
					self.neighbour, self.neighbourName = o.neighbour, o.neighbourName
					say(o.touch)
				elseif self.stepT > Tutorial.CONTACT_WAIT_S then
					advance(true, o.touch) -- nobody to attack yet
					return frame(nil)
				else
					self.neighbour = nil
					self.card.text = Tutorial.CONTACT_WAIT_LINE
					if self.idle > Tutorial.NUDGE_S then
						target = "frontier"
					end
				end
			end
			if self.neighbour ~= nil then
				target = "neighbour"
			end
		elseif id == "city" then
			if o.cityBuilt then
				advance(false, o.touch)
				return frame(nil)
			end
			-- (while the City is in hand the game's own banner stands where the
			-- card does: the card steps aside and only the mark leads on)
			self.card.visible = not o.placingCity
			if o.confirmOpen then
				target = "confirm"
			elseif o.placingCity then
				target = "ownLand"
			else
				target = "city"
			end
		end
		if self.stepT > (step.maxS or Tutorial.STEP_MAX_S) then
			advance(true, o.touch)
			return frame(nil)
		end
		return frame(target, word)
	end

	return run
end

export type Run = typeof(Tutorial.newRun())

return Tutorial
