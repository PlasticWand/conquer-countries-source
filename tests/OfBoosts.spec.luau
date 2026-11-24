-- In-match boosts (Bruno, 2026-11-23; Runner.boostCheck / useBoost): War
-- Chest, Instant Rearm, Second Spawn, and the profile's credits and Star
-- Boost (Store/Profile).
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local HumanProtection = t.require("OpenFront.HumanProtection")
	local Profile = t.require("Store.Profile")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function freeLandNear(game: any, x: number, y: number): number
		local map = game:map()
		for r = 0, 60 do
			for dy = -r, r do
				for dx = -r, r do
					local tile = map:ref(x + dx, y + dy)
					if map:isLand(tile) and not map:isImpassable(tile) and not game:hasOwner(tile) then
						return tile
					end
				end
			end
		end
		error("no land")
	end

	-- Ada in a solo match with the map's nations, just past the spawn phase.
	local function start(): (any, any, any)
		local runner = Runner.new({
			gameID = "boosts-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Singleplayer",
				difficulty = "Medium",
				bots = 0,
				nations = "default",
				extraWeapons = true,
			},
		})
		runner:addHuman("1001", "Ada", nil, {})
		runner:start()
		local game = runner.game
		t.eq(select(2, runner:boostCheck("1001", "warChest")), "spawning", "nothing in the spawn phase")
		runner:intent("1001", { type = "spawn", tile = freeLandNear(game, 520, 140) })
		for _ = 1, 4000 do
			if not game:inSpawnPhase() then
				break
			end
			runner:step()
		end
		for _ = 1, 20 do
			runner:step()
		end
		local ada = game:playerByClientID("1001")
		local nation = nil
		for _, p in game:allPlayers() do
			if p:type() == "NATION" and p:isAlive() and p:numTilesOwned() > 0 then
				nation = p
				break
			end
		end
		return runner, ada, nation
	end

	t.test("War Chest: at least 500K gold, then a two-minute wait", function()
		local runner, ada = start()
		local before = ada:gold()
		t.ok(runner:boostCheck("1001", "warChest"))
		t.ok(runner:useBoost("1001", "warChest"))
		t.ok(ada:gold() - before >= Runner.WAR_CHEST_MIN, "at least the minimum")
		t.eq(select(2, runner:boostCheck("1001", "warChest")), "wait")
		t.eq(runner:useBoost("1001", "warChest"), false, "not twice in a row")
		-- (Two minutes on, by the boost's clock: a real two minutes of AI
		-- nations could end Ada.)
		local used = (runner :: any).boostAt["1001"]
		used.warChest -= 1200
		t.ok(runner:boostCheck("1001", "warChest"), "again after two minutes")
	end)

	t.test("Instant Rearm: only when something is reloading; reloads it all", function()
		local runner, ada = start()
		t.eq(select(2, runner:boostCheck("1001", "rearm")), "nothing", "nothing to reload")
		local game = runner.game
		local tile = ada:spawnTile()
		local silo = ada:buildUnit("Missile Silo", tile, {})
		silo:launch()
		t.eq(#silo:missileTimerQueue(), 1, "fired, reloading")
		t.ok(runner:boostCheck("1001", "rearm"))
		t.ok(runner:useBoost("1001", "rearm"))
		t.eq(#silo:missileTimerQueue(), 0, "reloaded at once")
		silo:launch()
		t.eq(select(2, runner:boostCheck("1001", "rearm")), "wait", "once a minute")
		t.ok(game ~= nil)
	end)

	t.test("Second Spawn: once, within five minutes, on free land, with starting troops", function()
		local runner, ada, nation = start()
		local game = runner.game
		t.eq(select(2, runner:boostCheck("1001", "secondSpawn")), "alive", "not while alive")
		HumanProtection.surrender(game, ada, nation)
		runner:step()
		t.eq(ada:isAlive(), false, "Ada is out")
		local owned = (nation :: any):spawnTile()
		t.eq(select(2, runner:boostCheck("1001", "secondSpawn", owned)), "tile", "not on someone's land")
		local spot = freeLandNear(game, 300, 300)
		t.ok(runner:boostCheck("1001", "secondSpawn", spot))
		t.ok(runner:useBoost("1001", "secondSpawn", spot))
		t.ok(ada:isAlive(), "back in the match")
		t.eq(ada:spawnTile(), spot)
		for _ = 1, 30 do
			runner:step()
		end
		t.ok(ada:isAlive(), "still alive a few seconds later")
		t.ok(ada:troops() > 0, "with troops")
		HumanProtection.surrender(game, ada, nation)
		runner:step()
		t.eq(select(2, runner:boostCheck("1001", "secondSpawn", freeLandNear(game, 300, 300))), "used", "once a match")
	end)

	t.test("Second Spawn is too late after five minutes", function()
		local runner, ada, nation = start()
		for _ = 1, 3010 do
			runner:step()
		end
		HumanProtection.surrender(runner.game, ada, nation)
		runner:step()
		t.eq(select(2, runner:boostCheck("1001", "secondSpawn")), "late")
	end)

	t.test("profile: boost credits, spend and refund; Star Boost doubles its minutes", function()
		local p = Profile.new()
		t.eq(Profile.spendBoost(p, "warChest"), false, "none to spend")
		Profile.grant(p, "warChest", "r1", function()
			return 0.5
		end, 0)
		t.eq(p.boosts.warChest, 1)
		t.ok(Profile.spendBoost(p, "warChest"))
		t.eq(p.boosts.warChest, nil)
		Profile.refundBoost(p, "warChest")
		t.eq(p.boosts.warChest, 1, "refunded")
		local back = Profile.decode(Profile.encode(p)) :: any
		t.eq(back.boosts.warChest, 1, "saved")

		local q = Profile.new()
		local plain = Profile.applyMatch(Profile.new(), { won = false, placement = 5, players = 20, minutes = 10 }, false)
		Profile.grant(q, "starBoost", "s1", function()
			return 0.5
		end, 0)
		t.eq(q.starBoostLeft, 3600)
		local boosted = Profile.applyMatch(q, { won = false, placement = 5, players = 20, minutes = 10 }, false)
		t.eq(boosted, plain * 2, "double stars for boosted minutes")
		t.eq(q.starBoostLeft, 3000, "ten minutes used")
		local both = Profile.new()
		both.starBoostLeft = 3600
		t.eq(Profile.applyMatch(both, { won = false, placement = 5, players = 20, minutes = 10 }, true), plain * 4, "on top of 2x Stars")
	end)
end
