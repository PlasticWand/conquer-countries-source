--!strict
-- Ports checked against the v0.35.2 atlas masks and pass equations.
return function(t)
	local fs, luau = require("@lune/fs"), require("@lune/luau")
	local Harness = luau.load(fs.readFile("tests/harness.luau"))()
	local root = Harness.mount("src/client/Map/OpenFront", "OpenFront")
	local Atlas = Harness.require(root.SpriteAtlas)
	local Visual = Harness.require(root.UnitVisuals)
	local Clusters = Harness.require(root.NameClusters)
	t.test("OpenFront CC atlas code data reproduces all original alpha-mask bands", function()
		local pixels = Atlas.rgba()
		t.eq(buffer.len(pixels), 512 * 192 * 4)
		local counts = {0, 0, 0, 0}
		for band = 0, 3 do
			for y = 0, 12 do for x = 0, 155 do
				if buffer.readu8(pixels, ((band * 13 + y) * 512 + x) * 4 + 3) > 0 then counts[band + 1] += 1 end
			end end
		end
		-- Counts from the pinned resources/atlases/unit-atlas.png, Pillow RGBA.
		for i, expected in {135, 156, 5, 56} do t.eq(counts[i], expected) end
		local glyphs = 0
		for y = 56, 119 do for x = 0, 383 do
			if buffer.readu8(pixels, (y * 512 + x) * 4 + 3) > 0 then glyphs += 1 end
		end end
		t.eq(glyphs, 4628)
	end)
	t.test("all sixteen source unit types map to the right atlas and layer", function()
		for index, kind in {"City", "Port", "Factory", "Defense Post", "SAM Launcher", "Missile Silo"} do
			local col, structure = Visual.sprite({type = kind})
			t.eq(col, index - 1); t.eq(structure, true)
		end
		for index, kind in {"Transport", "Trade Ship", "Warship", "Atom Bomb", "Hydrogen Bomb", "MIRV", "SAMMissile", "Shell", "MIRV Warhead"} do
			local col, structure = Visual.sprite({type = kind})
			t.eq(col, index - 1); t.eq(structure, false)
		end
		t.eq(select(1, Visual.sprite({type = "Train", trainType = "Engine"})), 9)
		t.eq(select(1, Visual.sprite({type = "Train", trainType = "TailEngine"})), 9)
		t.eq(select(1, Visual.sprite({type = "Train", trainType = "Carriage", loaded = false})), 10)
		t.eq(select(1, Visual.sprite({type = "Train", trainType = "Carriage", loaded = true})), 11)
	end)
	t.test("missile smoothing, shell trail, warship combat, readiness and telegraphs", function()
		local v = Visual.unit({type = "Atom Bomb", active = true, waitTicks = 0, tile = 37, lastTile = 26, owner = 3}, 10, 2, .25)
		t.eq(v.x, 6.25); t.eq(v.y, 2.25); t.eq(v.missile, true); t.eq(v.size, 26)
		t.eq(Visual.unit({type = "Atom Bomb", active = true, waitTicks = 1, tile = 37}, 10, 2, .5), nil)
		t.eq(Visual.unit({type = "Shell", active = true, tile = 2, lastTile = 1}, 10, 3, 1).trailTile, 1)
		t.eq(Visual.unit({type = "Warship", active = true, tile = 2, warship = {state = "retreating"}}, 10, 3, 1).retreating, true)
		t.eq(Visual.progress({type = "SAM Launcher", level = 2, missileTimerQueue = {80}}, 100, 90, 300), .5 + 20 / 90 / 2)
		t.eq(Visual.progress({type = "City", underConstruction = true}, 100, 90, 300, 50), nil)
		t.eq(Visual.progress({type = "City", markedForDeletion = 250}, 100, 90, 300), .5)
		local ring = Visual.telegraph({type = "Hydrogen Bomb", active = true, waitTicks = 0, targetTile = 50}, 10)
		t.eq(ring.x, .5); t.eq(ring.y, 5.5); t.eq(ring.inner, 80); t.eq(ring.outer, 100)
		t.eq(Visual.telegraph({type = "MIRV", active = true, targetTile = 50}, 10), nil)
	end)
	t.test("singleton rail paths use OpenFront's vertical orientation with neither neighbour", function()
		-- RailroadPass.computePathOrientations explicitly handles length 1.
		-- Tile zero is valid; neither missing neighbour is a unit patch field.
		for _, tile in {0, 11, 63} do t.eq(Visual.railType(nil, tile, nil, 10), 1) end
	end)
	t.test("source rail turn and zoom gates", function()
		t.eq(Visual.railType(nil, 11, 21, 10), 1)
		t.eq(Visual.railType(10, 11, 12, 10), 2)
		t.eq(Visual.railType(21, 11, 12, 10), 6)
		t.eq(Visual.railType(21, 11, 10, 10), 5)
		t.eq(Visual.railFade(1), 0); t.eq(Visual.railFade(2), .5); t.eq(Visual.railFade(3), 1)
		local white, dark = {r = 1, g = 1, b = 1}, {r = .1, g = .1, b = .1}
		t.eq(Visual.railColor(0, 1, nil, nil).r, .75)
		t.eq(Visual.railColor(2, 1, white, dark).r, .1)
		t.eq(Visual.railColor(1, 1, white, dark).r, 0)
		t.eq(Visual.railColor(1, 1, dark, white).r, 230 / 255)
		t.eq(Visual.railColor(1, 1, white, dark, true).r, 230 / 255)
	end)
	t.test("name fallback chooses largest eight-neighbour border component", function()
		local b = Clusters.largestBorderBounds({1, 11, 22, 23, 24, 80, 81}, 10, 10)
		t.eq(b.min.x, 1); t.eq(b.min.y, 0)
		t.eq(b.max.x, 4); t.eq(b.max.y, 2)
	end)
end
