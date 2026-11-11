return function(t)
	local Rng = t.require("Rng")

	t.test("same seed gives the same sequence", function()
		local a, b = Rng.new(42), Rng.new(42)
		for _ = 1, 100 do
			t.eq(Rng.nextU32(a), Rng.nextU32(b))
		end
	end)

	t.test("int stays inside its inclusive range", function()
		local rng = Rng.new(7)
		local seenLo, seenHi = false, false
		for _ = 1, 2000 do
			local v = Rng.int(rng, 3, 6)
			t.ok(v >= 3 and v <= 6, `out of range: {v}`)
			seenLo = seenLo or v == 3
			seenHi = seenHi or v == 6
		end
		t.ok(seenLo and seenHi, "both ends reached")
	end)

	t.test("zero seed is usable", function()
		local rng = Rng.new(0)
		t.ok(Rng.nextU32(rng) ~= 0)
	end)
end
