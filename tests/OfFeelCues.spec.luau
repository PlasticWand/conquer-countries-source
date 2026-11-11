--!strict
-- FeelCues: the attack's second beat fires once, where your land first
-- meets the target's, and only for a fresh send toward a nation.
return function(t)
	local FeelCues = t.require("OpenFront.FeelCues")

	-- A 6x4 map: you (1) on the left columns, nation 3 on the right.
	local function state(): any
		local s: any = {
			you = 1,
			tick = 100,
			width = 6,
			height = 4,
			attacks = {},
			owners = {},
			players = {
				[1] = { smallID = 1, displayName = "You", alive = true },
				[3] = { smallID = 3, displayName = "Nation", type = "NATION", alive = true },
				[4] = { smallID = 4, displayName = "Tribe", type = "BOT", alive = true },
			},
		}
		for tile = 0, 23 do
			local x = tile % 6
			s.owners[tile] = if x <= 1 then 1 elseif x >= 4 then 3 else 0
		end
		function s.ownerAt(self: any, tile: number): number
			return self.owners[tile]
		end
		return s
	end

	t.test("a send toward a nation fires once, at the first tile beside their land", function()
		local s, f = state(), FeelCues.new()
		f:reset(s)
		s.attacks = { { id = 5, attacker = 1, target = 3, troops = 1000, outgoing = true } }
		s.tick = 101
		f:tick(s)
		-- Empty land taken first: not beside them.
		s.owners[2] = 1
		t.eq(#f:tiles(s, { 2 }), 0, "empty land is no contact")
		s.owners[3] = 1
		local out = f:tiles(s, { 3 })
		t.eq(#out, 1, "contact")
		t.eq(out[1].tile, 3, "at the tile beside their land")
		t.eq(out[1].other, 3, "against that nation")
		t.eq(out[1].kind, "impact")
		s.owners[9] = 1
		t.eq(#f:tiles(s, { 9 }), 0, "only once per send")
	end)

	t.test("expanding into empty land and attacks already under way stay quiet", function()
		local s, f = state(), FeelCues.new()
		s.attacks = { { id = 5, attacker = 1, target = 3, troops = 1000, outgoing = true } }
		f:reset(s)
		s.tick = 101
		f:tick(s)
		s.owners[3] = 1
		t.eq(#f:tiles(s, { 3 }), 0, "the snapshot's attack isn't news")
		s.attacks = { { id = 6, attacker = 1, target = 0, troops = 500, outgoing = true } }
		s.tick = 102
		f:tick(s)
		s.owners[9] = 1
		t.eq(#f:tiles(s, { 9 }), 0, "empty land has no second beat")
	end)

	t.test("more troops sent to the same attack arms it again; an armed send lapses", function()
		local s, f = state(), FeelCues.new()
		f:reset(s)
		s.attacks = { { id = 5, attacker = 1, target = 3, troops = 1000, outgoing = true } }
		s.tick = 101
		f:tick(s)
		s.owners[3] = 1
		t.eq(#f:tiles(s, { 3 }), 1, "first send")
		s.attacks[1].troops = 2000
		s.tick = 102
		f:tick(s)
		s.owners[9] = 1
		t.eq(#f:tiles(s, { 9 }), 1, "the reinforcement lands again")
		s.attacks[1].troops = 3000
		s.tick = 103
		f:tick(s)
		s.tick = 160
		f:tick(s)
		s.owners[15] = 1
		t.eq(#f:tiles(s, { 15 }), 0, "lapsed after 5 s without contact")
	end)

	t.test("an attack on you pings once where it first takes land beside yours", function()
		local s, f = state(), FeelCues.new()
		f:reset(s)
		s.attacks = { { id = 9, attacker = 3, target = 1, troops = 1000, outgoing = false } }
		s.tick = 101
		f:tick(s)
		-- Nation 3 takes column 2 (empty before), next to your column 1.
		s.owners[2] = 3
		local out = f:tiles(s, { 2 })
		t.eq(#out, 1, "ping")
		t.eq(out[1].kind, "loss")
		t.eq(out[1].tile, 2)
		t.eq(out[1].other, 3)
		s.owners[8] = 3
		t.eq(#f:tiles(s, { 8 }), 0, "once per attack")
		f:armLosses(s)
		s.owners[14] = 3
		t.eq(#f:tiles(s, { 14 }), 1, "the land-falling alarm pings again")
	end)

	t.test("tribes and the snapshot's attacks don't ping", function()
		local s, f = state(), FeelCues.new()
		s.attacks = { { id = 9, attacker = 3, target = 1, troops = 1000, outgoing = false } }
		f:reset(s)
		s.tick = 101
		f:tick(s)
		s.owners[2] = 3
		t.eq(#f:tiles(s, { 2 }), 0, "already under way at the snapshot")
		s.attacks = { { id = 10, attacker = 4, target = 1, troops = 1000, outgoing = false } }
		s.tick = 102
		f:tick(s)
		s.owners[8] = 4
		t.eq(#f:tiles(s, { 8 }), 0, "a tribe's attack is left out, as in the attacks list")
	end)
end
