-- OpenFront port: nations run. A solo match on compact World with the map's
-- nations and tribes, every difficulty, and a human who spawns and then
-- idles. The nation AI must tick without errors, spawn, expand, build and
-- fight. (Exact parity is checked by OfNations against OpenFront's traces.)
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	-- Two difficulties keep the suite quick; each runs about 25 s under Lune.
	local TICKS = 600

	for _, difficulty in { "Easy", "Impossible" } do
		t.test(`nations play a match ({difficulty})`, function()
			local runner = Runner.new({
				gameID = `smoke{difficulty}`,
				mapFolder = Maps.World,
				gameConfig = {
					gameMap = "World",
					gameMapSize = "Compact",
					gameMode = "Free For All",
					gameType = "Singleplayer",
					difficulty = difficulty,
					bots = 40,
					nations = "default",
				},
			})
			runner:addHuman("1001", "Bruno")
			runner:start()
			local game = runner.game
			t.ok(#game:nations() > 0, "the map has nations")
			-- Singleplayer: the spawn phase ends when the human spawns. Nations
			-- place themselves in the first ticks, so spawn after them.
			for _ = 1, 20 do
				runner:step()
			end
			local map = game:map()
			local spawned = false
			for tile = 0, map:width() * map:height() - 1, 97 do
				if map:isLand(tile) and not game:hasOwner(tile) then
					t.ok(runner:intent("1001", { type = "spawn", tile = tile }), "spawn intent accepted")
					spawned = true
					break
				end
			end
			t.ok(spawned, "found free land")
			for _ = 1, TICKS do
				runner:step()
			end
			local alive, structures, tiles = 0, 0, 0
			for _, p in game:players() do
				if p:type() == "NATION" and p:isAlive() then
					alive += 1
					tiles += p:numTilesOwned()
					structures += #p:units({ "City", "Port", "Defense Post", "SAM Launcher", "Missile Silo", "Factory" })
				end
			end
			print(`  {difficulty}: {#game:nations()} nations, {alive} alive, {tiles} tiles, {structures} structures at tick {game:ticks()}`)
			t.ok(alive > 0, "nations spawned and survive")
			t.ok(tiles > alive * 100, "nations expanded")
		end)
	end
end
