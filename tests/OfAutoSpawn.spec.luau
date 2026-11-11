-- Unplaced humans in multiplayer (a Conquest addition, Bruno 2026-10-28):
-- with gameConfig.autoSpawnUnplaced, a human who hasn't picked a start when
-- the spawn timer runs out gets a random one. Without it they sit the match
-- out, as in OpenFront.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function play(autoSpawn: boolean?): (any, any, any)
		local runner = Runner.new({
			gameID = "auto-spawn",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				autoSpawnUnplaced = autoSpawn,
			},
		})
		runner:addHuman("1001", "Picker")
		runner:addHuman("1002", "Idle")
		runner:start()
		local game = runner.game
		-- The picker places a capital; the idle player never does.
		local map = game:map()
		local tile
		for dx = 0, 40 do
			local candidate = map:ref(520 + dx, 130)
			if map:isLand(candidate) and not map:isImpassable(candidate) then
				tile = candidate
				break
			end
		end
		runner:intent("1001", { type = "spawn", tile = tile })
		local spawnTurns = game:config():numSpawnPhaseTurns()
		for _ = 1, spawnTurns + 5 do
			runner:step()
		end
		return game, game:playerByClientID("1001"), game:playerByClientID("1002")
	end

	t.test("without the setting an unplaced player sits out (OpenFront)", function()
		local game, picker, idle = play(nil)
		t.eq(game:inSpawnPhase(), false, "the match started")
		t.ok(picker:hasSpawned(), "the picker is in")
		t.eq(idle:hasSpawned(), false, "the idle player is out")
	end)

	t.test("with it the idle player gets a random capital as the match starts", function()
		local game, picker, idle = play(true)
		t.eq(game:inSpawnPhase(), false, "the match started")
		t.ok(picker:hasSpawned(), "the picker is in")
		t.ok(idle:hasSpawned(), "the idle player was placed")
		t.ok(idle:spawnTile() ~= nil and idle:numTilesOwned() > 0, "with a capital and land")
		t.ok(idle:spawnTile() ~= picker:spawnTile(), "somewhere else")
	end)
end
