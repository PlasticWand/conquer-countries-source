-- Conquest's own Arsenal item, Paratroopers (docs/design/ARSENAL_V2.md):
-- a plane from a City or Airfield carries troops up to 120 tiles and lands
-- like a boat; enemy SAMs can shoot it down. Through the real runner on
-- compact World.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local Para = t.require("OpenFront.Executions.ParatroopersExecution")
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

	-- Ada and Bea in a public match, 80 tiles apart, past the spawn phase.
	local function start(adaWeapons: { [string]: boolean }?): (any, any, any)
		local runner = Runner.new({
			gameID = "para-test",
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
		return runner, game:playerByClientID("1001"), game:playerByClientID("1002")
	end

	-- Ada with a City, gold and troops, and a target deep in Bea's land.
	local function ready(): (any, any, any, any, number)
		local runner, ada, bea = start({ paratroopers = true })
		ada:addGold(10_000_000)
		local city = ada:buildUnit("City", ada:tiles():values()[1], {})
		ada:setTroops(400_000)
		bea:setTroops(50_000)
		return runner, ada, bea, city, bea:tiles():values()[1]
	end

	-- Steps until the drop's plane takes off.
	local function launched(runner: any): any
		for _ = 1, 5 do
			runner:step()
			local plane = runner.game:units("Paratroopers")[1]
			if plane then
				return plane
			end
		end
		return nil
	end

	-- Steps until the plane is gone; the messages sent meanwhile.
	local function fly(runner: any, plane: any): { any }
		local messages = {}
		for _ = 1, 200 do
			local gone = not plane:isActive()
			runner:step() -- (one more: the execution reports a loss the tick after)
			for _, m in runner.game:drainMessages() do
				table.insert(messages, m)
			end
			if gone then
				return messages
			end
		end
		error("the plane never arrived")
	end

	t.test("locked without the unlock; 250K; needs a City or Airfield in reach", function()
		local runner, ada, bea = start(nil)
		ada:addGold(10_000_000)
		ada:buildUnit("City", ada:tiles():values()[1], {})
		local target = bea:tiles():values()[1]
		t.eq(ada:canBuild("Paratroopers", target), false, "locked")
		runner, ada, bea = start({ paratroopers = true })
		local game = runner.game
		ada:addGold(10_000_000)
		target = bea:tiles():values()[1]
		t.eq(game:unitInfo("Paratroopers").cost(game, ada), 250_000)
		t.eq(ada:canBuild("Paratroopers", target), false, "no City or Airfield yet")
		local city = ada:buildUnit("City", ada:tiles():values()[1], {})
		t.eq(ada:canBuild("Paratroopers", target), city:tile(), "takes off from the City")
		t.eq(ada:canBuild("Paratroopers", ada:tiles():values()[2]), false, "never your own land")
		local map = game:map()
		local far = landNear(map, map:x(city:tile()) + 200, map:y(city:tile()))
		t.eq(ada:canBuild("Paratroopers", far), false, "beyond 120 tiles")
		local snap = Replication.newReplicator(runner):snapshot("1001")
		t.eq(snap.arsenal.weapons.paratroopers, true)
		t.eq(snap.arsenal.paraReadyAt, 0)
		t.eq(snap.costs.Paratroopers, 250_000)
	end)

	t.test("a drop flies, takes the tile and attacks from it; capped at 25% of the cap", function()
		local runner, ada, bea, city, target = ready()
		local game = runner.game
		local gold = ada:gold()
		local cap = math.floor(game:config():maxTroops(ada) * Para.MAX_SHARE)
		local preview = runner:buildPreview("1001", target, "Paratroopers")
		t.eq(preview.paraAim.originTile, city:tile())
		t.eq(preview.paraAim.reach, 120)
		runner:intent("1001", { type = "build_action", unit = "Paratroopers", tile = target, troops = 10_000_000 })
		local plane = launched(runner)
		t.eq(#game:units("Paratroopers"), 1, "one plane in the air")
		t.eq(plane:troops(), math.min(cap, 400_000), "never more than 25% of the cap")
		local spent = gold - ada:gold()
		t.ok(spent > 240_000 and spent <= 250_000, `250K paid, less a few ticks' income ({spent})`)
		t.eq(plane._sourceTile, city:tile())
		t.eq(ada:canBuild("Paratroopers", bea:tiles():values()[2]), false, "one at a time")
		local beaTiles = bea:numTilesOwned()
		fly(runner, plane)
		t.ok(plane:reachedTarget(), "it landed")
		t.eq(game:owner(target), ada, "took the landing tile")
		t.ok(bea:numTilesOwned() < beaTiles - 1, "and attacks Bea from it (90K overruns her 50 tiles)")
		local snap = Replication.newReplicator(runner):snapshot("1001")
		t.ok(snap.arsenal.paraReadyAt > game:ticks(), "the cooldown shows")
		local map = game:map()
		local empty = landNear(map, map:x(city:tile()) + 30, map:y(city:tile()) + 30)
		t.eq(ada:canBuild("Paratroopers", empty), false, "60 s before the next")
		for _ = 1, Para.COOLDOWN do
			runner:step()
		end
		t.ok(ada:canBuild("Paratroopers", empty) ~= false, "ready again")
	end)

	t.test("a landing zone inside enemy land holds for 30 s, then OpenFront's enclosure rule applies", function()
		local runner, ada, bea = ready()
		local game = runner.game
		-- A big, well-held Bea, so the pocket is sealed in her land.
		local map = game:map()
		local home = bea:tiles():values()[1]
		local cx, cy = map:x(home), map:y(home)
		for y = cy - 20, cy + 20 do
			for x = cx - 20, cx + 20 do
				local tile = map:ref(x, y)
				if map:isLand(tile) and not map:hasOwner(tile) then
					bea:conquer(tile)
				end
			end
		end
		bea:setTroops(2_000_000)
		-- A tile of hers with no water within 8 tiles.
		local target = nil
		for y = cy - 12, cy + 12 do
			for x = cx - 12, cx + 12 do
				local dry = true
				for dy = -8, 8 do
					for dx = -8, 8 do
						if not map:isLand(map:ref(x + dx, y + dy)) then
							dry = false
						end
					end
				end
				if dry and target == nil and game:owner(map:ref(x, y)) == bea then
					target = map:ref(x, y)
				end
			end
		end
		assert(target, "an inland tile")
		runner:intent("1001", { type = "build_action", unit = "Paratroopers", tile = target, troops = 5_000 })
		local plane = launched(runner)
		fly(runner, plane)
		t.eq(game:owner(target), ada, "landed")
		for _ = 1, 40 do
			runner:step()
		end
		t.eq(game:owner(target), ada, "still held after several cluster checks")
		for _ = 1, Para.HOLD do
			runner:step()
		end
		-- (The source rechecks only after its land changes.)
		local map = game:map()
		local city = ada:units("City")[1]
		ada:conquer(landNear(map, map:x(city:tile()) + 20, map:y(city:tile())))
		for _ = 1, 3 do
			runner:step()
		end
		t.eq(game:owner(target), bea, "then the pocket goes to Bea, as in OpenFront")
	end)

	t.test("an enemy SAM in range shoots it down, troops and all", function()
		local runner, ada, bea, _, target = ready()
		local game = runner.game
		local sam = bea:buildUnit("SAM Launcher", target, {})
		runner:intent("1001", { type = "build_action", unit = "Paratroopers", tile = target, troops = 50_000 })
		local plane = launched(runner)
		t.ok(plane ~= nil)
		local messages = fly(runner, plane)
		t.eq(plane:reachedTarget(), false, "never landed")
		t.ok(sam:isInCooldown(), "the SAM used a missile")
		t.ok(game:owner(target) == bea, "Bea keeps the tile")
		local shot = false
		for _, m in messages do
			if m.key == "events_display.paratroopers_shot_down" and m.playerId == ada:id() then
				shot = true
			end
		end
		t.ok(shot, "Ada is told")
	end)

	t.test("landing on land that became ours sends the troops home", function()
		local runner, ada, _, city = ready()
		local game = runner.game
		-- Empty land in reach (an island of ours inside Bea's land would be
		-- annexed back by the source's enclosure rule).
		local map = game:map()
		local target = landNear(map, map:x(city:tile()) + 30, map:y(city:tile()) + 30)
		runner:intent("1001", { type = "build_action", unit = "Paratroopers", tile = target, troops = 40_000 })
		local plane = launched(runner)
		ada:conquer(target)
		local home = 0
		local addTroops = ada.addTroops
		ada.addTroops = function(self: any, n: number)
			if n >= 1000 then
				home += n
			end
			return addTroops(self, n)
		end
		local messages = fly(runner, plane)
		ada.addTroops = addTroops
		t.eq(home, 40_000, "all 40K home")
		local said = false
		for _, m in messages do
			said = said or m.key == "events_display.paratroopers_returned"
		end
		t.ok(said, "and says so")
	end)

	t.test("build_action checks its troops; other builds ignore them", function()
		local runner, _, _, _, target = ready()
		local ok, reason = runner:intent("1001", { type = "build_action", unit = "Paratroopers", tile = target, troops = "lots" })
		t.eq(ok, false)
		t.eq(reason, "badRequest")
	end)
end
