--!strict
-- The crate opening's pure timing: the track samples cleanly between frames,
-- the three taps' beats line up with the Blender track, and a 3-pack comes out
-- rarest last, going right, left, then the middle.
return function(t)
	local fs, luau = require("@lune/fs"), require("@lune/luau")
	local Harness = luau.load(fs.readFile("tests/harness.luau"))()
	local root = Harness.mount("src/client/Ui/Crate", "CrateUi")
	local CrateTimeline = Harness.require(root.CrateTimeline)
	local CrateTrack = Harness.require(root.CrateTrack)

	local CARD_HALF_HEIGHT = 0.41 -- CrateOpening's CARD_SIZE.Y / 2, before scale
	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	t.test("the track covers every part, the card and the camera for every frame", function()
		local n = #CrateTrack.camera
		t.ok(n == 244, `frames {n}`)
		for _, name in { "Body", "Lid", "Strap0", "Strap1", "Catch0", "Catch1", "Card" } do
			local frames = CrateTrack.parts[name]
			t.ok(frames ~= nil and #frames == n, `{name} frames`)
			for _, f in frames do
				t.ok(#f == 10, `{name} frame size`)
				local q = math.sqrt(f[4] ^ 2 + f[5] ^ 2 + f[6] ^ 2 + f[7] ^ 2)
				t.ok(near(q, 1, 2e-3), `{name} quaternion length {q}`)
			end
			t.ok(CrateTrack.offset[name] ~= nil, `{name} offset`)
		end
	end)

	t.test("each tap breaks its own piece", function()
		local seg, hidden = CrateTrack.segments, CrateTrack.hidden
		t.ok(seg.tap1[1] <= CrateTimeline.TAP_BREAK[1] and CrateTimeline.TAP_BREAK[1] <= seg.tap1[2], "catches pop in tap 1")
		t.ok(not CrateTimeline.hidden(hidden.Strap0, seg.wait1[2]), "straps still on before tap 2")
		t.ok(CrateTimeline.hidden(hidden.Strap0, seg.wait2[1] + 5), "straps gone in the next wait")
		t.ok(not CrateTimeline.hidden(hidden.Lid, seg.wait2[2]), "lid still on before tap 3")
		t.ok(CrateTimeline.hidden(hidden.Lid, seg.tap3[2]), "lid gone after tap 3")
		t.ok(not CrateTimeline.hidden(hidden.Body, 240), "body stays")
		t.ok(seg.card[1] == CrateTimeline.CARD_RISE and seg.card[2] == CrateTimeline.CARD_SETTLED, "card segment")
		local turn = CrateTimeline.CARD_TURN
		t.ok(CrateTimeline.CARD_RISE < turn[1] and turn[2] <= CrateTimeline.CARD_SETTLED, "turns between rising and settling")
	end)

	t.test("a card bursts out of the crate, comes to the camera and is edge-on at the flip", function()
		local frames, first = CrateTrack.parts.Card, CrateTrack.firstFrame
		local start = CrateTimeline.sample(frames, first, CrateTimeline.CARD_RISE)
		local top = CrateTimeline.sample(frames, first, 214)
		local landed = CrateTimeline.sample(frames, first, CrateTimeline.CARD_SETTLED)
		t.ok(start[2] < 0.82, "starts inside, below the rim")
		t.ok(top[2] > start[2] + 0.4, "rises well clear")
		t.ok(landed[2] < top[2], "then comes down")
		-- Bruno: it clipped through the front wall. While it is over the crate
		-- after the peek, its bottom edge stays above the rim (0.82); it only
		-- comes down once it is in front of the front face.
		local half = CARD_HALF_HEIGHT
		for f = 211, CrateTimeline.CARD_SETTLED, 0.25 do
			local s = CrateTimeline.sample(frames, first, f)
			local fromCentre = math.sqrt(s[1] * s[1] + s[3] * s[3])
			if fromCentre < 0.55 then
				t.ok(s[2] - half * s[9] > 0.82, `clear of the rim at {f}`)
			end
		end
		-- A real half turn: before it the card's back (local -z, the Front
		-- face) faces the camera, after it its face (local +z); edge-on midway.
		local function facing(frame: number): number
			local f = CrateTimeline.sample(frames, first, frame)
			local qx, qy, qz, qw = f[4], f[5], f[6], f[7]
			local nx, nz = 2 * (qx * qz + qw * qy), 1 - 2 * (qx * qx + qy * qy) -- local +z in the world
			local cam = CrateTimeline.camera(CrateTrack.camera, first, frame)
			local vx, vz = cam[1] - f[1], cam[3] - f[3] -- towards the camera
			return (nx * vx + nz * vz) / (math.sqrt(nx * nx + nz * nz) * math.sqrt(vx * vx + vz * vz))
		end
		local turn = CrateTimeline.CARD_TURN
		t.ok(facing(turn[1]) < -0.9, `back to the camera before the turn ({facing(turn[1])})`)
		t.ok(facing(turn[2]) > 0.9, `face to the camera after it ({facing(turn[2])})`)
		t.ok(math.abs(facing((turn[1] + turn[2]) / 2)) < 0.35, "edge-on midway")
	end)

	t.test("sampling hits the frames exactly and stays unit between them", function()
		local frames = CrateTrack.parts.Lid
		local first = CrateTrack.firstFrame
		for _, f in { 1, 40, 70, 160 } do
			local s = CrateTimeline.sample(frames, first, f)
			for j = 1, 3 do
				t.ok(near(s[j], frames[f][j], 1e-9), `frame {f} position`)
			end
		end
		for f = 150, 175, 0.37 do
			local s = CrateTimeline.sample(frames, first, f)
			t.ok(near(math.sqrt(s[4] ^ 2 + s[5] ^ 2 + s[6] ^ 2 + s[7] ^ 2), 1, 1e-9), `unit at {f}`)
		end
		local past = CrateTimeline.sample(frames, first, 500)
		t.ok(near(past[2], frames[#frames][2], 1e-9), "holds the end")
	end)

	t.test("waits loop, the rest hold their end", function()
		local wait = CrateTrack.segments.wait1
		local length = (wait[2] - wait[1]) / CrateTimeline.FPS
		t.ok(near(CrateTimeline.at(wait, length + 0.1, true), wait[1] + 0.1 * CrateTimeline.FPS, 1e-6), "wraps")
		t.ok(near(CrateTimeline.at(CrateTrack.segments.tap3, 999), CrateTrack.segments.tap3[2]), "holds")
	end)

	t.test("a 3-pack: rarest last, right, left, then the middle", function()
		local order = CrateTimeline.order({ "legendary", "common", "rare" })
		t.ok(order[1] == 2 and order[2] == 3 and order[3] == 1, "common, rare, legendary")
		local ties = CrateTimeline.order({ "rare", "rare", "common" })
		t.ok(ties[1] == 3 and ties[2] == 1 and ties[3] == 2, "ties as rolled")
		t.ok(CrateTimeline.slot(1, 3) == 1 and CrateTimeline.slot(2, 3) == -1 and CrateTimeline.slot(3, 3) == 0, "slots")
		t.ok(CrateTimeline.slot(1, 1) == 0, "a single card stays in the middle")
		t.ok(CrateTimeline.best({ "common", "epic", "rare" }) == "epic", "best of three")
	end)

	t.test("rarity looks", function()
		t.ok(CrateTimeline.LOOK.legendary.legendary and not CrateTimeline.LOOK.epic.legendary, "only Legendary turns dark")
		t.ok(not CrateTimeline.LOOK.common.seams and CrateTimeline.LOOK.rare.seams, "seams from Rare")
		t.ok(CrateTimeline.LEAK[3] < CrateTimeline.LEAK[1], "more light after each tap")
	end)

	t.test("field of view: Blender's frame always fits", function()
		local hfov, ra = CrateTrack.horizontalFov, CrateTrack.renderAspect
		local blenderV = CrateTimeline.verticalFov(hfov, ra, ra)
		t.ok(near(CrateTimeline.verticalFov(hfov, 2.3, ra), blenderV, 1e-9), "a wider screen keeps the height")
		t.ok(CrateTimeline.verticalFov(hfov, 1.2, ra) > blenderV, "a narrower one opens up to keep the width")
		t.ok(CrateTimeline.verticalFov(hfov, 0.3, ra) == 70, "capped")
	end)
end
