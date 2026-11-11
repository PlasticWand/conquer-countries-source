-- Conquest's own Arsenal item, Sabotage (docs/design/ARSENAL_V2.md): a fuse on
-- an enemy building, then 30 s dark: no firing, launching, defending or
-- earning. Through the real runner on compact World.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local Sabotage = t.require("OpenFront.Executions.SabotageExecution")
	local AttackExecution = t.require("OpenFront.Executions.AttackExecution")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function landNear(map: any, x: number, y: number): number
		for r = 0, 40 do
			for dy = -r, r do
				for dx = -r, r do
					local tile = map:ref(x + dx, y + dy)
					if map:isLand(tile) and not map:isImpassable(tile) and not map:hasOwner(tile) then
						return tile
					end
				end
			end
		end
		error("no land")
	end

	-- Ada and Bea 50 tiles apart, past the spawn phase.
	local function start(adaWeapons: { [string]: boolean }?): (any, any, any)
		local runner = Runner.new({
			gameID = "sabotage-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				extraWeapons = true,
				spawnImmunityDuration = 0,
			},
		})
		runner:addHuman("1001", "Ada", nil, { weapons = adaWeapons })
		runner:addHuman("1002", "Bea")
		runner:start()
		local game = runner.game
		local map = game:map()
		runner:intent("1001", { type = "spawn", tile = landNear(map, 520, 140) })
		runner:intent("1002", { type = "spawn", tile = landNear(map, 570, 140) })
		for _ = 1, 4000 do
			if not game:inSpawnPhase() then
				break
			end
			runner:step()
		end
		for _ = 1, 20 do
			runner:step()
		end
		local ada, bea = game:playerByClientID("1001"), game:playerByClientID("1002")
		ada:addGold(10_000_000)
		return runner, ada, bea
	end

	local function steps(runner: any, n: number)
		for _ = 1, n do
			runner:step()
		end
	end

	-- Sends a sabotage at `unit` and steps past the fuse.
	local function sabotage(runner: any, unit: any)
		runner:intent("1001", { type = "build_action", unit = "Sabotage", tile = unit:tile() })
		steps(runner, Sabotage.FUSE + 5)
	end

	t.test("locked without the unlock; 500K; only enemy buildings in reach", function()
		local runner, ada, bea = start(nil)
		local sam = bea:buildUnit("SAM Launcher", bea:tiles():values()[1], {})
		t.eq(ada:canBuild("Sabotage", sam:tile()), false, "locked")
		runner, ada, bea = start({ sabotage = true })
		local game = runner.game
		sam = bea:buildUnit("SAM Launcher", bea:tiles():values()[1], {})
		t.eq(game:unitInfo("Sabotage").cost(game, ada), 500_000)
		t.eq(ada:canBuild("Sabotage", sam:tile()), sam:tile(), "aims at Bea's SAM")
		local own = ada:buildUnit("City", ada:tiles():values()[1], {})
		t.eq(ada:canBuild("Sabotage", own:tile()), false, "never your own")
		local map = game:map()
		local far = landNear(map, map:x(sam:tile()) + 150, map:y(sam:tile()))
		bea:conquer(far)
		local remote = bea:buildUnit("City", far, {})
		t.eq(ada:canBuild("Sabotage", remote:tile()), false, "more than 60 tiles from Ada's land")
	end)

	t.test("a 5 s fuse, then 30 s dark; one at a time, 90 s apart", function()
		local runner, ada, bea = start({ sabotage = true })
		local game = runner.game
		local silo = bea:buildUnit("Missile Silo", bea:tiles():values()[1], {})
		local gold = ada:gold()
		runner:intent("1001", { type = "build_action", unit = "Sabotage", tile = silo:tile() })
		steps(runner, 3)
		t.eq(#game:units("Sabotage"), 1, "a visible fuse")
		local spent = gold - ada:gold()
		t.ok(spent > 490_000 and spent <= 500_000, `500K paid ({spent})`)
		t.eq(silo:isDark(), false, "not yet")
		steps(runner, Sabotage.FUSE)
		t.eq(#game:units("Sabotage"), 0, "the fuse burned out")
		t.ok(silo:isDark(), "dark")
		t.eq(bea:canBuild("Atom Bomb", ada:tiles():values()[1]), false, "a dark silo can't launch")
		local snap = Replication.newReplicator(runner):snapshot("1002")
		local rec = nil
		for _, u in snap.units do
			if u.id == silo:id() then
				rec = u
			end
		end
		t.ok(rec ~= nil and rec.dark == true, "clients see it dark")
		t.ok(Replication.newReplicator(runner):snapshot("1001").arsenal.sabotageReadyAt > game:ticks())
		steps(runner, Sabotage.DARK)
		t.eq(silo:isDark(), false, "back after 30 s")
		t.eq(game.darkCount, 0)
	end)

	t.test("a dark defence post gives no bonus", function()
		local runner, ada, bea = start({ sabotage = true })
		local game = runner.game
		local tile = bea:tiles():values()[1]
		local post = bea:buildUnit("Defense Post", tile, {})
		local attack = AttackExecution.new(1000, ada, bea:id(), nil)
		attack.mg, attack.map, attack.target = game, game:map(), bea
		t.eq(attack:_attackLogicInput(1000, tile, 10).defenderHasDefensePost, true, "the post counts")
		sabotage(runner, post)
		t.ok(post:isDark())
		t.eq(attack:_attackLogicInput(1000, tile, 10).defenderHasDefensePost, false, "not while dark")
	end)

	t.test("a dark SAM lets Paratroopers through", function()
		local runner, ada, bea = start({ sabotage = true, paratroopers = true })
		local game = runner.game
		local target = bea:tiles():values()[1]
		local sam = bea:buildUnit("SAM Launcher", target, {})
		ada:buildUnit("City", ada:tiles():values()[1], {})
		ada:setTroops(100_000)
		sabotage(runner, sam)
		t.ok(sam:isDark())
		runner:intent("1001", { type = "build_action", unit = "Paratroopers", tile = target, troops = 20_000 })
		local plane = nil
		for _ = 1, 5 do
			runner:step()
			plane = plane or game:units("Paratroopers")[1]
		end
		t.ok(plane ~= nil, "launched")
		for _ = 1, 100 do
			if not plane:isActive() then
				break
			end
			runner:step()
		end
		t.ok(plane:reachedTarget(), "landed under a dark SAM")
		t.eq(sam:isInCooldown(), false, "it never fired")
	end)

	t.test("it fizzles if the building is gone when the fuse ends", function()
		local runner, ada, bea = start({ sabotage = true })
		local game = runner.game
		local city = bea:buildUnit("City", bea:tiles():values()[1], {})
		runner:intent("1001", { type = "build_action", unit = "Sabotage", tile = city:tile() })
		steps(runner, 3)
		city:delete(false)
		steps(runner, Sabotage.FUSE + 5)
		t.eq(#game:units("Sabotage"), 0)
		t.eq(game.darkCount or 0, 0, "nothing went dark")
		t.ok(ada ~= nil)
	end)
end
