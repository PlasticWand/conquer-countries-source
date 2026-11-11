-- Conquest's own Arsenal item, Field Works (docs/design/ARSENAL_V2.md):
-- temporary earthworks near a front with a defence post's effect within 15
-- tiles for 60 s. Through the real runner on compact World.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local FieldWorks = t.require("OpenFront.Executions.FieldWorksExecution")
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

	-- Ada and Bea with a front: Bea holds a tile next to Ada's border.
	local function start(adaWeapons: { [string]: boolean }?): (any, any, any, number, number)
		local runner = Runner.new({
			gameID = "fieldworks-test",
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
		runner:intent("1002", { type = "spawn", tile = landNear(map, 600, 140) })
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
		-- The front: a tile of Bea's beside one of Ada's border tiles.
		local front, theirs = nil, nil
		for _, b in ada:borderTiles():values() do
			for _, n in map:neighbors(b) do
				if front == nil and map:isLand(n) and not map:hasOwner(n) then
					front, theirs = b, n
				end
			end
		end
		assert(front and theirs, "a border")
		bea:conquer(theirs :: number)
		return runner, ada, bea, front :: number, theirs :: number
	end

	local function steps(runner: any, n: number)
		for _ = 1, n do
			runner:step()
		end
	end

	-- Ada's own tile about `d` tiles from `from`, or nil.
	local function ownTileAway(game: any, ada: any, from: number, d: number): number?
		local map = game:map()
		for _, tile in ada:tiles():values() do
			local dx, dy = map:x(tile) - map:x(from), map:y(tile) - map:y(from)
			if math.abs(math.sqrt(dx * dx + dy * dy) - d) < 1 then
				return tile
			end
		end
		return nil
	end

	t.test("locked without the unlock; 100K; only on our land near a front", function()
		local runner, ada, _, front = start(nil)
		t.eq(ada:canBuild("Field Works", front), false, "locked")
		local game
		runner, ada, _, front = start({ fieldWorks = true })
		game = runner.game
		t.eq(game:unitInfo("Field Works").cost(game, ada), 100_000)
		t.eq(ada:canBuild("Field Works", front), front, "beside Bea's land")
		local inland = ownTileAway(game, ada, front, 9)
		if inland then
			t.eq(ada:canBuild("Field Works", inland), false, "9 tiles from the front")
		end
	end)

	t.test("built in 1 s, defends within 15 tiles, gone after 60 s; two at a time, 30 s apart", function()
		local runner, ada, bea, front = start({ fieldWorks = true })
		local game = runner.game
		local attack = AttackExecution.new(1000, bea, ada:id(), nil)
		attack.mg, attack.map, attack.target = game, game:map(), ada
		t.eq(attack:_attackLogicInput(1000, front, 10).defenderHasDefensePost, false, "no bonus before")
		runner:intent("1001", { type = "build_action", unit = "Field Works", tile = front })
		steps(runner, 3)
		local works = game:units("Field Works")[1]
		t.ok(works ~= nil, "placed")
		t.ok(works:isUnderConstruction(), "digging")
		t.eq(attack:_attackLogicInput(1000, front, 10).defenderHasDefensePost, false, "not while digging")
		steps(runner, FieldWorks.BUILD)
		t.eq(works:isUnderConstruction(), false, "dug")
		t.eq(attack:_attackLogicInput(1000, front, 10).defenderHasDefensePost, true, "a defence post's effect")
		local far = ownTileAway(game, ada, works:tile(), 20)
		if far then
			t.eq(attack:_attackLogicInput(1000, far, 10).defenderHasDefensePost, false, "not 20 tiles away")
		end
		local snap = Replication.newReplicator(runner):snapshot("1001")
		local rec = nil
		for _, u in snap.units do
			if u.id == works:id() then
				rec = u
			end
		end
		t.ok(rec ~= nil and rec.expiresAt ~= nil and rec.expiresAt > game:ticks(), "clients see when it goes")
		t.ok(snap.arsenal.fieldWorksReadyAt > game:ticks(), "the cooldown shows")
		t.eq(ada:canBuild("Field Works", front), false, "30 s before the next")
		steps(runner, FieldWorks.LIFETIME)
		t.eq(works:isActive(), false, "gone after 60 s")
		t.eq(game.fieldWorksCount, 0)
	end)

	t.test("at most two standing", function()
		local runner, ada, _, front = start({ fieldWorks = true, rapidReload = true })
		local game = runner.game
		ada:buildUnit("Field Works", front, {})
		ada:buildUnit("Field Works", front, {})
		t.eq(ada:canBuild("Field Works", front), false, "two already")
		t.ok(game ~= nil)
	end)

	t.test("losing its tile removes it", function()
		local runner, ada, bea, front = start({ fieldWorks = true })
		local game = runner.game
		runner:intent("1001", { type = "build_action", unit = "Field Works", tile = front })
		steps(runner, 3)
		local works = game:units("Field Works")[1]
		bea:conquer(front)
		steps(runner, 2)
		t.eq(works:isActive(), false, "gone with its tile")
		t.eq(game.fieldWorksCount, 0)
		t.ok(ada ~= nil)
	end)
end
