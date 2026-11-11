-- Conquest's Arsenal (beyond OpenFront, behind gameConfig.extraWeapons):
-- Reinforcements and the Mega Nuke, through the real runner on compact World.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local Config = t.require("OpenFront.Config")
	local EngineConfig = t.require("OpenFront.EngineConfig")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function start(extra: boolean, weapons: { [string]: boolean }?): any
		local runner = Runner.new({
			gameID = "arsenal-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Singleplayer",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				extraWeapons = extra,
			},
		})
		runner:addHuman("1001", "Ada", nil, { weapons = weapons })
		runner:start()
		local map = runner.game:map()
		local spawn = nil
		for dy = 0, 40 do
			for dx = 0, 40 do
				local tile = map:ref(520 + dx, 130 + dy)
				if spawn == nil and map:isLand(tile) and not map:isImpassable(tile) then
					spawn = tile
				end
			end
		end
		runner:intent("1001", { type = "spawn", tile = spawn })
		-- Past the singleplayer spawn phase (Config.numSpawnPhaseTurns).
		for _ = 1, 110 do
			runner:step()
		end
		return runner
	end

	t.test("Reinforcements: unlock and flag required; gold, cap and cooldown", function()
		local off = start(false, { reinforcements = true })
		t.eq(select(2, off:intent("1001", { type = "reinforce" })), "unsupported", "off unless the match turns extra weapons on")

		local locked = start(true, nil)
		local me = locked.game:playerByClientID("1001")
		me:addGold(1_000_000)
		local before = me:troops()
		locked:intent("1001", { type = "reinforce" })
		locked:step()
		locked:step()
		t.eq(me:troops() >= before, true)
		t.eq(me:gold() >= 1_000_000, true, "nothing spent without the unlock")

		local runner = start(true, { reinforcements = true })
		local game = runner.game
		me = game:playerByClientID("1001")
		me:addGold(1_000_000)
		-- Make room under the limit.
		me:removeTroops(me:troops() * 0.5)
		local gold, troops = me:gold(), me:troops()
		local max = game:config():maxTroops(me)
		-- An execution added this turn acts on the next.
		runner:intent("1001", { type = "reinforce" })
		runner:step()
		runner:step()
		local added = me:troops() - troops
		t.ok(added >= math.floor(math.min(max * Config.REINFORCE_SHARE, max - troops)) - 1, `added {added}`)
		t.ok(me:gold() <= gold - Config.REINFORCE_GOLD + 1000, "paid in gold")
		t.ok(me:troops() <= max, "never above the troop limit")
		local after = me:troops()
		runner:intent("1001", { type = "reinforce" })
		runner:step()
		runner:step()
		t.ok(me:troops() - after < added / 2, "the cooldown blocks a second call")
		local snap = Replication.newReplicator(runner):snapshot("1001")
		t.eq(snap.arsenal.weapons.reinforcements, true, "the viewer learns what they unlocked")
		t.ok(snap.arsenal.reinforceReadyAt > game:ticks(), "and when it's ready again")
	end)

	t.test("Mega Nuke: buildable only when unlocked, and twice the Atom Bomb's radius", function()
		local c = EngineConfig.new({ difficulty = "Medium" } :: any, false)
		t.eq(c:nukeMagnitudes("Mega Nuke").outer, 2 * c:nukeMagnitudes("Atom Bomb").outer)
		t.ok(c:nukeSpeed("Mega Nuke") < c:nukeSpeed("Atom Bomb"), "slower, so it's seen longer")
		local locked = start(true, nil)
		local me = locked.game:playerByClientID("1001")
		me:addGold(10_000_000)
		t.eq(me:canBuild("Mega Nuke", me:spawnTile()), false, "locked")
		local snap = Replication.newReplicator(locked):snapshot("1001")
		t.eq(snap.costs["Mega Nuke"], nil, "no price for those who can't build it")
		local runner = start(true, { megaNuke = true })
		me = runner.game:playerByClientID("1001")
		t.eq(me:hasExtraWeapon("megaNuke"), true)
		local costs = Replication.newReplicator(runner):snapshot("1001").costs
		t.eq(costs["Mega Nuke"], 2_500_000)
		local off = start(false, { megaNuke = true })
		t.eq(off.game:playerByClientID("1001"):hasExtraWeapon("megaNuke"), false, "flag off: no extra weapons")
	end)

	t.test("Mega Nuke: a launch flies, detonates and clears units in its radius", function()
		-- Regression: the blast's unit sweep deleted the Mega Nuke itself (it was
		-- missing from GameTypes.Nukes), so every detonation errored.
		local runner = start(true, { megaNuke = true })
		local game = runner.game
		local me = game:playerByClientID("1001")
		me:addGold(10_000_000)
		local tiles = me:tiles():values()
		me:buildUnit("Missile Silo", tiles[1], {})
		local aim = tiles[#tiles]
		local city = me:buildUnit("City", aim, {})
		local gold = me:gold()
		runner:intent("1001", { type = "build_unit", unit = "Mega Nuke", tile = aim })
		local launched, landed = false, false
		for _ = 1, 200 do
			runner:step()
			local flying = #game:units("Mega Nuke") > 0
			launched = launched or flying
			if launched and not flying then
				landed = true
				break
			end
		end
		t.eq(launched, true, "launched")
		t.eq(landed, true, "detonated without an error")
		t.eq(city:isActive(), false, "the City at ground zero is destroyed")
		t.ok(gold - me:gold() >= 2_500_000 - 100_000, "paid 2.5M (less income in flight)")
	end)

	t.test("Mega Nuke: the build preview answers, with the silo's aim", function()
		-- Regression: buildPreview only took OpenFront's PlayerBuildable, so the
		-- Mega Nuke got no ghost, blast ring or aim arc before the click.
		local off = start(false, { megaNuke = true })
		t.eq(off:buildPreview("1001", off.game:playerByClientID("1001"):spawnTile(), "Mega Nuke"), nil, "flag off: no preview")
		local runner = start(true, { megaNuke = true })
		local me = runner.game:playerByClientID("1001")
		me:addGold(10_000_000)
		local tiles = me:tiles():values()
		me:buildUnit("Missile Silo", tiles[1], {})
		local preview = runner:buildPreview("1001", tiles[#tiles], "Mega Nuke") :: any
		t.ok(preview ~= nil, "answered")
		t.eq(preview.unit, "Mega Nuke")
		t.eq(preview.buildable.canBuild ~= false, true, "buildable with the unlock and gold")
		t.ok(preview.nukeAim ~= nil and preview.nukeAim.siloTile == tiles[1], "aimed from the ready silo")
	end)
end
