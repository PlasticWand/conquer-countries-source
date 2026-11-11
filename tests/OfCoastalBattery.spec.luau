-- Conquest's own Arsenal item, the Coastal Battery (docs/design/ARSENAL_V2.md):
-- a shore gun that fires OpenFront's warship shell at enemy boats within 40
-- tiles. Through the real runner on compact World.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Battery = t.require("OpenFront.Executions.CoastalBatteryExecution")
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

	local function start(adaWeapons: { [string]: boolean }?): (any, any, any)
		local runner = Runner.new({
			gameID = "coastal-test",
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

	-- A shore tile of Ada's (conquered for the test if she has none) and an
	-- ocean tile 10-30 tiles off it.
	local function coast(game: any, ada: any): (number, number)
		local map = game:map()
		local home = ada:tiles():values()[1]
		local hx, hy = map:x(home), map:y(home)
		local shore = nil
		for r = 0, 120 do
			for dy = -r, r do
				for dx = -r, r do
					local x, y = hx + dx, hy + dy
					if shore == nil and x >= 0 and y >= 0 and x < map:width() and y < map:height() then
						local tile = map:ref(x, y)
						if map:isLand(tile) and map:isShore(tile) and (not map:hasOwner(tile) or game:owner(tile) == ada) then
							shore = tile
						end
					end
				end
			end
			if shore then
				break
			end
		end
		assert(shore, "a shore")
		ada:conquer(shore)
		local sx, sy = map:x(shore), map:y(shore)
		for r = 10, 30 do
			for dy = -r, r do
				for dx = -r, r do
					local x, y = sx + dx, sy + dy
					if x >= 0 and y >= 0 and x < map:width() and y < map:height() then
						local tile = map:ref(x, y)
						if map:isOcean(tile) and dx * dx + dy * dy <= 30 * 30 then
							return shore, tile
						end
					end
				end
			end
		end
		error("no sea near the shore")
	end

	local function battery(game: any, ada: any, tile: number): any
		local unit = ada:buildUnit("Coastal Battery", tile, {})
		game:addExecution(Battery.new(unit))
		return unit
	end

	t.test("locked without the unlock; 400K +400K each; snaps to the shore", function()
		local runner, ada = start(nil)
		local game = runner.game
		ada:addGold(10_000_000)
		local shore = coast(game, ada)
		t.eq(ada:canBuild("Coastal Battery", shore), false, "locked")
		runner, ada = start({ coastalBattery = true })
		game = runner.game
		ada:addGold(10_000_000)
		shore = coast(game, ada)
		t.eq(game:unitInfo("Coastal Battery").cost(game, ada), 400_000)
		local at = ada:canBuild("Coastal Battery", shore)
		t.ok(at ~= false and game:map():isShore(at :: number), "on a shore tile")
		ada:buildUnit("Coastal Battery", at, {})
		t.eq(game:unitInfo("Coastal Battery").cost(game, ada), 800_000, "+400K each")
		t.eq(game:unitInfo("Coastal Battery").maxHealth, 800)
	end)

	t.test("one shell sinks an enemy transport in range", function()
		local runner, ada, bea = start({ coastalBattery = true })
		local game = runner.game
		local shore, sea = coast(game, ada)
		battery(game, ada, shore)
		local boat = bea:buildUnit("Transport", sea, { troops = 5000, targetTile = shore })
		local shells = 0
		for _ = 1, 60 do
			runner:step()
			shells = math.max(shells, #game:units("Shell"))
			if not boat:isActive() then
				break
			end
		end
		t.ok(shells >= 1, "a visible shell")
		t.eq(boat:isActive(), false, "sunk")
	end)

	t.test("warships take a shell's damage; friends are never shot", function()
		local runner, ada, bea = start({ coastalBattery = true })
		local game = runner.game
		local shore, sea = coast(game, ada)
		battery(game, ada, shore)
		local own = ada:buildUnit("Transport", sea, { troops = 5000, targetTile = shore })
		local ship = bea:buildUnit("Warship", sea, { patrolTile = sea })
		local health = ship:health()
		for _ = 1, 40 do
			runner:step()
		end
		t.ok(ship:health() < health, `damaged ({health} -> {ship:health()})`)
		t.ok(own:isActive(), "its own boat is safe")
	end)

	t.test("fires every 30 ticks, 15 with Rapid Reload", function()
		local _, ada = start({ coastalBattery = true, rapidReload = true })
		local Config = t.require("OpenFront.Config")
		t.eq(Battery.RELOAD, 30)
		t.eq(Config.rapidReload(ada, Battery.RELOAD), 15)
		t.eq(Battery.RANGE, 40)
	end)
end
