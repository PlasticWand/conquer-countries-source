-- SpatialQuery._bfsNearest's ring path (a Conquest speed-up) must return
-- exactly what OpenFront's bounded depth-first walk returns, ties included.
return function(t)
	local GameMap = t.require("OpenFront.GameMap")
	local SpatialQuery = t.require("OpenFront.Pathfinding.SpatialQuery")

	local W, H = 300, 220
	local map = GameMap.new(W, H, buffer.create(W * H), 0)
	local scratch = { visited = buffer.create(W * H * 4), stack = {}, gen = 0 }
	local game = {
		map = function()
			return map
		end,
		traversalScratch = function()
			return scratch
		end,
		bumpTraversalGeneration = function()
			scratch.gen += 1
			return scratch.gen
		end,
	}

	-- The original walk (SpatialQuery.ts bfsNearest), copied verbatim.
	local function walk(from: number, maxDist: number, predicate: (number) -> boolean): number?
		local gen = game.bumpTraversalGeneration()
		local visited, stack = scratch.visited, {}
		local best, bestDist = nil, math.huge
		local function mark(tile: number)
			buffer.writeu32(visited, tile * 4, gen)
			table.insert(stack, tile)
			if predicate(tile) then
				local dist = map:manhattanDist(from, tile)
				if dist < bestDist then
					best, bestDist = tile, dist
				end
			end
		end
		if maxDist >= 0 then
			mark(from)
		end
		while #stack > 0 do
			map:forEachNeighbor(table.remove(stack) :: number, function(n: number)
				if buffer.readu32(visited, n * 4) ~= gen and map:manhattanDist(from, n) <= maxDist then
					mark(n)
				end
			end)
		end
		return best
	end

	-- A small deterministic hash in [0, 1).
	local function hash(a: number, b: number): number
		local h = bit32.bxor(a * 374761393, b * 668265263)
		h = bit32.bxor(h, bit32.rshift(h, 13)) * 1274126177
		return bit32.band(bit32.bxor(h, bit32.rshift(h, 16)), 0xffffff) / 0x1000000
	end

	t.test("the ring path matches the walk: sparse targets, ties, misses and map edges", function()
		local query = SpatialQuery.new(game)
		local cases, hits, ringCases = 0, 0, 0
		for i = 1, 400 do
			local from = math.floor(hash(i, 1) * W * H)
			local radius = ({ 0, 1, 7, 50, 50, 50 })[math.floor(hash(i, 2) * 6) + 1]
			-- Sparse random targets, often several at the same distance.
			local density = ({ 0, 0.0005, 0.003, 0.05 })[math.floor(hash(i, 3) * 4) + 1]
			local function predicate(tile: number): boolean
				return hash(i * 7919, tile) < density
			end
			local x, y = from % W, from // W
			if x - radius >= 0 and x + radius < W and y - radius >= 0 and y + radius < H then
				ringCases += 1
			end
			local expected = walk(from, radius, predicate)
			t.eq(query:_bfsNearest(from, radius, predicate), expected, `from {from} radius {radius} density {density}`)
			cases += 1
			if expected then
				hits += 1
			end
		end
		t.ok(hits > 50 and cases - hits > 50, "both hits and misses are covered")
		t.ok(ringCases > 200, "most cases take the ring path")
	end)
end
