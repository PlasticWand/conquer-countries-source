--!strict
-- AudioCues: which confirmed change makes which sound, and the throttles
-- that keep bursts to one cue.
return function(t)
	local AudioCues = t.require("OpenFront.AudioCues")

	local function state(): any
		local s: any = {
			you = 1,
			tick = 100,
			width = 100,
			winner = nil,
			startTick = 50,
			units = {},
			attacks = {},
			players = {
				[1] = { smallID = 1, id = "me000001", type = "HUMAN", alive = true, tiles = 500 },
				[2] = { smallID = 2, id = "bea00002", type = "HUMAN", alive = true, tiles = 300 },
				[3] = { smallID = 3, id = "nat00003", type = "NATION", alive = true, tiles = 300 },
			},
		}
		function s.inSpawnPhase(self: any): boolean
			return self.startTick == nil
		end
		function s.me(self: any): any
			return self.players[self.you]
		end
		return s
	end
	local function unit(id: number, type: string, owner: number, extra: { [string]: any }?): any
		local u: { [string]: any } = { id = id, type = type, owner = owner, active = true, level = 1, tile = 0 }
		for k, v in extra or {} do
			u[k] = v
		end
		return u
	end
	local function has(list: { string }, key: string): boolean
		return table.find(list, key) ~= nil
	end

	t.test("your builds and anyone's launches sound; others' builds don't", function()
		local s, c = state(), AudioCues.new()
		c:reset(s)
		local out = c:units(s, { unit(1, "City", 1), unit(2, "City", 2), unit(3, "Atom Bomb", 2), unit(4, "Transport", 1) }, {})
		t.ok(has(out, "build.city"), "own city")
		t.ok(has(out, "wpn.atomLaunch"), "anyone's atom bomb")
		t.ok(has(out, "naval.boat"), "own boat")
		t.eq(#out, 3, "the rival's city is silent")
	end)

	t.test("Artillery and Coastal Battery shots only up close; warship shells as before", function()
		local s, c = state(), AudioCues.new()
		s.units[5] = unit(5, "Coastal Battery", 1, { tile = 250 })
		c:reset(s)
		local near: { [number]: boolean } = {}
		c.hearAt = function(tile: number): boolean
			return near[tile] == true
		end
		local out = c:units(s, { unit(10, "Artillery Shell", 1, { sourceTile = 120, tile = 121 }) }, {})
		t.ok(not has(out, "wpn.artilleryFire"), "own artillery unheard far away")
		out = c:units(s, { unit(11, "Shell", 1, { sourceTile = 250 }) }, {})
		t.ok(not has(out, "naval.shell"), "own battery unheard far away")
		out = c:units(s, { unit(12, "Shell", 1, { sourceTile = 333 }) }, {})
		t.ok(has(out, "naval.shell"), "a warship's shell still heard")
		near[120], near[250] = true, true
		s.tick += 50
		out = c:units(s, { unit(13, "Artillery Shell", 1, { sourceTile = 120, tile = 121 }), unit(14, "Shell", 1, { sourceTile = 250 }) }, {})
		t.ok(has(out, "wpn.artilleryFire"), "heard zoomed in on it")
		t.ok(has(out, "naval.shell"), "the battery too")
	end)

	t.test("what was there at the snapshot stays silent; an upgrade sounds", function()
		local s, c = state(), AudioCues.new()
		s.units[7] = unit(7, "City", 1)
		c:reset(s)
		t.eq(#c:units(s, { unit(7, "City", 1) }, {}), 0, "known unit")
		local out = c:units(s, { unit(7, "City", 1, { level = 2 }) }, {})
		t.ok(has(out, "build.upgrade"), "level up")
	end)

	t.test("detonations, and MIRV warheads at most one boom per five ticks", function()
		local s, c = state(), AudioCues.new()
		c:reset(s)
		c:units(s, { unit(1, "Atom Bomb", 2), unit(2, "MIRV Warhead", 2), unit(3, "MIRV Warhead", 2), unit(4, "MIRV Warhead", 2) }, {})
		s.tick = 101
		local out = c:units(s, { unit(1, "Atom Bomb", 2, { active = false, reachedTarget = true }), unit(2, "MIRV Warhead", 2, { active = false, reachedTarget = true }), unit(3, "MIRV Warhead", 2, { active = false, reachedTarget = true }) }, {})
		t.ok(has(out, "wpn.atomHit"), "atom hit")
		t.eq(#out, 2, "one MIRV boom for two warheads")
		s.tick = 103
		t.eq(#c:units(s, { unit(4, "MIRV Warhead", 2, { active = false, reachedTarget = true }) }, {}), 0, "within the gap")
	end)

	t.test("boats: yours landing, an enemy's landing on you, your warship sunk", function()
		local s, c = state(), AudioCues.new()
		c:reset(s)
		c:units(s, { unit(1, "Transport", 1), unit(2, "Transport", 2), unit(3, "Warship", 1) }, {})
		c:messages(s, { { kind = "NAVAL_INVASION_INBOUND", params = { unitId = 2 } } })
		local out = c:units(s, { unit(1, "Transport", 1, { active = false, reachedTarget = true }), unit(2, "Transport", 2, { active = false, reachedTarget = true }) }, { 3 })
		t.ok(has(out, "naval.landed"), "own landing")
		t.ok(has(out, "alert.boat"), "enemy landing")
		t.ok(has(out, "naval.sunk"), "warship gone")
	end)

	t.test("messages and diplomacy", function()
		local s, c = state(), AudioCues.new()
		c:reset(s)
		local out = c:messages(s, { { kind = "NUKE_INBOUND" }, { kind = "MIRV_INBOUND" }, { kind = "UNIT_DESTROYED", key = "events_display.unit_voluntarily_deleted" } })
		t.ok(has(out, "alert.nuke") and has(out, "build.delete"), "alarm and delete")
		t.eq(#out, 2, "one alarm for two warnings")
		out = c:events(s, {
			{ type = "AllianceRequest", requestorID = 2, recipientID = 1 },
			{ type = "ConquestEvent", conquerorId = "me000001", conqueredId = "bea00002" },
		})
		t.ok(has(out, "dip.request"), "request")
		t.ok(has(out, "act.conquerHuman") and has(out, "end.flag"), "human conquered, swords")
		out = c:events(s, { { type = "ConquestEvent", conquerorId = "me000001", conqueredId = "nat00003" } })
		t.ok(has(out, "act.conquerBot"), "a nation pays out")
		out = c:events(s, { { type = "AllianceRequestReply", request = { requestorID = 1, recipientID = 2 }, accepted = false } })
		t.ok(has(out, "dip.declined"), "your request refused")
	end)

	t.test("the phase, attacks and land", function()
		local s, c = state(), AudioCues.new()
		s.startTick = nil
		c:reset(s)
		s.startTick = 100
		t.ok(has(c:tick(s), "act.start"), "spawn phase over")
		s.tick = 101
		s.attacks = { { id = 9, attacker = 2, target = 1, troops = 100, outgoing = false } }
		t.ok(has(c:tick(s), "alert.attacked"), "new attack on you")
		s.tick = 102
		t.ok(not has(c:tick(s), "alert.attacked"), "the same attack again is silent")
		s.attacks = { { id = 5, attacker = 1, target = 0, troops = 100, outgoing = true } }
		s.players[1].tiles = 510
		s.tick = 103
		c:tick(s)
		t.ok(c.expanding, "the troops loop plays while land grows")
		s.tick = 112
		c:tick(s)
		t.ok(not c.expanding, "and stops once it hasn't grown for a while")
		s.players[1].tiles = 400
		s.tick = 104
		t.ok(has(c:tick(s), "alert.losing"), "land falling fast")
		s.winner = "me000001"
		s.tick = 105
		t.ok(has(c:tick(s), "end.victory"), "you won")
	end)

	t.test("construction finishing has its own sound, for your structures only", function()
		local s, c = state(), AudioCues.new()
		c:reset(s)
		t.ok(has(c:units(s, { unit(1, "City", 1, { underConstruction = true }), unit(2, "City", 2, { underConstruction = true }) }, {}), "build.city"), "placed")
		t.eq(#c:units(s, { unit(1, "City", 1, { underConstruction = true }) }, {}), 0, "still building")
		local out = c:units(s, { unit(1, "City", 1), unit(2, "City", 2) }, {})
		t.ok(has(out, "build.done"), "yours finished")
		t.eq(#out, 1, "the rival's is silent")
		t.eq(#c:units(s, { unit(1, "City", 1) }, {}), 0, "only once")
	end)

	t.test("the pops rise over a run of growth and drop when it ends", function()
		local s, c = state(), AudioCues.new()
		c:reset(s)
		s.attacks = { { id = 5, attacker = 1, target = 0, troops = 100, outgoing = true } }
		c:tick(s)
		for i = 1, 20 do
			s.tick = 100 + i
			s.players[1].tiles = 500 + 10 * i
			c:tick(s)
		end
		t.near(c.popRise, 0.5, 1e-9, "half way after 20 growing ticks")
		for i = 21, 80 do
			s.tick = 100 + i
			s.players[1].tiles = 500 + 10 * i
			c:tick(s)
		end
		t.eq(c.popRise, 1, "capped")
		s.tick = 200
		c:tick(s)
		t.eq(c.popRise, 0, "back down once the land stops growing")
	end)

	t.test("ambience: nearest structure on zoom, else the sea", function()
		local s = state()
		s.units[1] = unit(1, "City", 2, { tile = 5 * 100 + 5 })
		local water = function(_tile: number): boolean
			return true
		end
		local key, gain = AudioCues.ambience(s, 5 * 100 + 10, 14, water)
		t.eq(key, "amb.city")
		t.near(gain, 0.5, 1e-9, "half way up the zoom envelope")
		t.eq((AudioCues.ambience(s, 5 * 100 + 10, 6, water)), nil, "zoomed out")
		t.eq((AudioCues.ambience(s, 90 * 100 + 90, 14, water)), "amb.ocean", "open sea")
	end)
end
