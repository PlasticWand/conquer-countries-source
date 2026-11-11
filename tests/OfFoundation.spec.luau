-- OpenFront port, Phase A foundation: DetMath and PseudoRandom must match
-- OpenFront v0.35.2 bit for bit. The fixture was produced by running
-- OpenFront's own DetMath.ts and PseudoRandom.ts under Node 24
-- (tests/fixtures/openfront/detmath-rng.txt); %.17g round-trips a double.
return function(t)
	local DetMath = t.require("OpenFront.DetMath")
	local PseudoRandom = t.require("OpenFront.PseudoRandom")

	local lines = string.split(t.readFile("tests/fixtures/openfront/detmath-rng.txt"), "\n")

	local function num(s: string): number
		if s == "Infinity" then
			return math.huge
		elseif s == "-Infinity" then
			return -math.huge
		end
		return assert(tonumber(s), s)
	end

	local function same(actual: number, expected: number, label: string)
		-- Exact equality, so 1-ulp differences fail.
		if actual ~= expected then
			error(`{label}: expected {string.format("%.17g", expected)}, got {string.format("%.17g", actual)}`, 2)
		end
	end

	t.test("exp, log, pow, pow2 and atan2 match OpenFront bit for bit", function()
		local counts = { exp = 0, log = 0, pow = 0, pow2 = 0, atan2 = 0 }
		for _, line in lines do
			local f = string.split(line, " ")
			local kind = f[1]
			if kind == "exp" then
				same(DetMath.exp(num(f[2])), num(f[3]), line)
			elseif kind == "log" then
				same(DetMath.log(num(f[2])), num(f[3]), line)
			elseif kind == "pow" then
				same(DetMath.pow(num(f[2]), num(f[3])), num(f[4]), line)
			elseif kind == "pow2" then
				same(DetMath.pow2(num(f[2])), num(f[3]), line)
			elseif kind == "atan2" then
				same(DetMath.atan2(num(f[2]), num(f[3])), num(f[4]), line)
			end
			if counts[kind] then
				counts[kind] += 1
			end
		end
		t.ok(counts.exp > 300 and counts.log > 300 and counts.pow > 300 and counts.atan2 > 300, "fixture loaded")
	end)

	t.test("PseudoRandom streams match OpenFront for odd seeds", function()
		local seen = 0
		for _, line in lines do
			local f = string.split(line, " ")
			if f[1] == "rng" then
				seen += 1
				local seed = num(f[2])
				local r = PseudoRandom.new(seed)
				for i, v in string.split(f[3], ",") do
					same(r:next(), num(v), `seed {f[2]} next #{i}`)
				end
				t.eq(r:nextID(), f[5], `seed {f[2]} nextID`)
				local r2 = PseudoRandom.new(seed)
				for i, v in string.split(f[4], ",") do
					t.eq(r2:nextInt(-7, 1000), num(v), `seed {f[2]} nextInt #{i}`)
				end
			end
		end
		t.eq(seen, 6, "six seeds")
	end)

	t.test("PseudoRandom state round-trips", function()
		local a = PseudoRandom.new(99)
		a:next()
		local b = PseudoRandom.fromState(a:getState())
		for _ = 1, 20 do
			t.eq(a:next(), b:next())
		end
	end)
end
