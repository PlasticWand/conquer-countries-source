-- The solo deploy countdown (a Conquest addition, Bruno 2026-10-27): with
-- gameConfig.soloDeployCountdown, placing your capital leaves the spawn
-- phase open for that many seconds from the first placement (moves don't
-- restart it, Bruno 2026-10-29), and the client sees the deadline. Without it, singleplayer ends the spawn phase on the
-- first placement, as OpenFront does.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local ClientState = t.require("OpenFront.ClientState")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function newRunner(countdown: number?): any
		local runner = Runner.new({
			gameID = "deploy-countdown",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Singleplayer",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				soloDeployCountdown = countdown,
			},
		})
		runner:addHuman("1001", "Bruno")
		runner:start()
		return runner
	end

	-- Free land near (x, y) on the compact World map.
	local function landNear(game: any, x: number, y: number): number
		local map = game:map()
		for dy = 0, 40 do
			for dx = 0, 40 do
				local tile = map:ref(x + dx, y + dy)
				if map:isLand(tile) and not map:isImpassable(tile) and not game:hasOwner(tile) then
					return tile
				end
			end
		end
		error("no land")
	end

	t.test("without the setting the first placement starts the match (OpenFront)", function()
		local runner = newRunner(nil)
		runner:intent("1001", { type = "spawn", tile = landNear(runner.game, 520, 130) })
		runner:step()
		runner:step()
		t.eq(runner.game:inSpawnPhase(), false, "spawn phase over")
	end)

	t.test("with it the capital can move for 5 s from the first pick; a move keeps the count", function()
		local runner = newRunner(5)
		local game = runner.game
		local rep = Replication.newReplicator(runner)
		local client = ClientState.new()
		client:applySnapshot(rep:snapshot("1001"))
		local function step(n: number)
			for _ = 1, n do
				runner:step()
				client:applyDelta(rep:forViewer(rep:collect(), "1001", game:drainMessages()))
			end
		end

		runner:intent("1001", { type = "spawn", tile = landNear(game, 520, 130) })
		step(2)
		local first = client.deployDeadline
		t.ok(first ~= nil, "the client sees the deadline")
		t.ok(game:inSpawnPhase() and client:inSpawnPhase(), "still choosing")
		step(30)
		t.ok(game:inSpawnPhase(), "3 s in, still choosing")

		-- Move the capital: the count carries on and the old disc is given up.
		local me = game:playerByClientID("1001")
		local before = me:spawnTile()
		runner:intent("1001", { type = "spawn", tile = landNear(game, 700, 200) })
		step(2)
		t.ok(me:spawnTile() ~= before, "the capital moved")
		t.eq(client.deployDeadline, first, "the count didn't restart")
		t.eq(game:owner(before) ~= me, true, "the old spot is free again")

		step(12)
		t.ok(game:inSpawnPhase(), "4.6 s after the first pick, still choosing")
		step(10)
		t.eq(game:inSpawnPhase(), false, "deployed 5 s after the first pick")
		t.eq(client:inSpawnPhase(), false, "the client sees the match start")
	end)
end
