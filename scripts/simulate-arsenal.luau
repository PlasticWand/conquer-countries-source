-- lune run scripts/simulate-arsenal reinforce [matches] [ticks]
-- lune run scripts/simulate-arsenal strike [atTick] [nosams]
-- Checks what Conquest's Arsenal weapons do to a match (docs/design/
-- rofront-ui-pass.md). Every match is compact World with Medium nations and
-- 100 tribes; the same gameID gives the same seed. A solo match's spawn phase
-- ends when its human spawns, so an idle human spawns at the map's far south.
-- A scripted human is too weak a player to show anything, so OpenFront's own
-- nations (Medium AI) stand in for competent players. Nations never use the
-- Arsenal in real matches.
--
-- reinforce: each match is played twice. The first run uses no Arsenal; the
-- nation ranked 3rd by land at tick 1000 there (strong, not leading) is then
-- given Reinforcements in the second run, called whenever they are ready and
-- affordable. Prints that nation's land share, rank by land, troops and gold
-- every 1000 ticks for both runs, then the Reinforce uses and their gold.
--
-- strike: one match is played to atTick four times. Each time the largest
-- nation (given 10M gold and, if it has none, a Missile Silo) fires at the
-- second largest nation's first City: nothing, an Atom Bomb, a Mega Nuke or a
-- Hydrogen Bomb. Prints, 30 s after launch, what the target lost against the
-- run with no bomb, and the land the bomb left unowned. SAMs shoot bombs down
-- near their launch and target, so with `nosams` every other player's SAM
-- Launchers are removed just before launch (in all four runs), which measures
-- the blast itself.

local process = require("@lune/process")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local Runner = Harness.require(Shared.OpenFront.Runner)
local Config = Harness.require(Shared.OpenFront.Config)
local Reinforce = Harness.require(Shared.OpenFront.Executions.ReinforceExecution)
local Construction = Harness.require(Shared.OpenFront.Executions.ConstructionExecution)

local mode = process.args[1] or "reinforce"
local Maps = Harness.mount("src/maps", "OpenFrontMaps")

local function newMatch(gameID: string): (any, any, number)
	local runner = Runner.new({
		gameID = gameID,
		mapFolder = Maps.World,
		gameConfig = {
			gameMap = "World",
			gameMapSize = "Compact",
			gameMode = "Free For All",
			gameType = "Singleplayer",
			difficulty = "Medium",
			bots = 100,
			nations = "default",
			extraWeapons = true,
		},
	})
	runner:addHuman("1", "Idle")
	runner:start()
	local game = runner.game
	local map = game:map()
	local landTotal = 0
	local spawn = nil
	for tile = map:width() * map:height() - 1, 0, -1 do
		if map:isLand(tile) then
			landTotal += 1
			if spawn == nil and not map:isImpassable(tile) and not map:hasOwner(tile) then
				spawn = tile
			end
		end
	end
	runner:intent("1", { type = "spawn", tile = spawn })
	return runner, game, landTotal
end

type Sample = { tick: number, alive: boolean, land: number, rank: number, troops: number, gold: number, nation: boolean }

-- Samples every player (by name) every 1000 ticks. With `reinforced`, that
-- nation calls Reinforcements whenever it can.
local function play(gameID: string, maxTicks: number, reinforced: string?): ({ [string]: { Sample } }, number)
	local runner, game, landTotal = newMatch(gameID)
	local nation = nil
	local samples: { [string]: { Sample } } = {}
	local uses = 0
	for tick = 1, maxTicks do
		if reinforced and nation == nil then
			for _, p in game:allPlayers() do
				if p:name() == reinforced then
					nation = p
					p.playerInfo.weapons = { reinforcements = true }
				end
			end
		end
		if nation and tick % 10 == 0 and Reinforce.check(game, nation) ~= nil then
			game:addExecution(Reinforce.new(nation))
		end
		local readyAt = nation and nation.reinforceReadyAt
		runner:step()
		if nation and nation.reinforceReadyAt ~= readyAt then
			uses += 1
		end
		if tick % 1000 == 0 then
			local players = table.clone(game:allPlayers())
			table.sort(players, function(a, b)
				return a:numTilesOwned() > b:numTilesOwned()
			end)
			for rank, p in players do
				local list = samples[p:name()] or {}
				samples[p:name()] = list
				table.insert(list, {
					tick = tick,
					alive = p:isAlive(),
					land = p:numTilesOwned() / landTotal,
					rank = rank,
					troops = p:troops(),
					gold = p:gold(),
					nation = p:type() == "NATION",
				})
			end
		end
		if game:getWinner() ~= nil then
			break
		end
	end
	return samples, uses
end

local function reinforce(matches: number, maxTicks: number)
	for m = 1, matches do
		local id = string.format("arsenal%03d", m)
		local without = play(id, maxTicks, nil)
		local pick = nil
		for name, list in without do
			local first = list[1]
			if first and first.nation and first.alive and (pick == nil or first.rank < without[pick][1].rank) and first.rank >= 3 then
				pick = name
			end
		end
		assert(pick, "no nation to pick")
		local withAll, uses = play(id, maxTicks, pick)
		local a, b = without[pick], withAll[pick] or {}
		print(`match {id}, {pick}: Reinforcements every {Config.REINFORCE_COOLDOWN // 10} s for {Config.REINFORCE_GOLD} gold, +{Config.REINFORCE_SHARE * 100}% of the troop limit (without -> with)`)
		for i, x in a do
			local y = b[i]
			if y then
				print(string.format("  tick %5d   land %5.2f%% -> %5.2f%%   rank %3d -> %3d   troops %7d -> %7d   gold %9d -> %9d%s", x.tick, x.land * 100, y.land * 100, x.rank, y.rank, x.troops, y.troops, x.gold, y.gold, if x.alive and y.alive then "" else "   (dead)"))
			end
		end
		print(`  Reinforce used {uses} times for {uses * Config.REINFORCE_GOLD} gold`)
	end
end

type Strike = { launcher: string, target: string, sams: number, tiles: number, troops: number, unowned: number, flight: number?, cost: number, inner: number, outer: number }

local function strikeOnce(atTick: number, bomb: string?, noSams: boolean): Strike
	local runner, game = newMatch("strike001")
	for _ = 1, atTick do
		runner:step()
	end
	local nations = {}
	for _, p in game:players() do
		if p:type() == "NATION" and p:isAlive() then
			table.insert(nations, p)
		end
	end
	table.sort(nations, function(a, b)
		return a:numTilesOwned() > b:numTilesOwned()
	end)
	local launcher, target = nations[1], nations[2]
	local cities = target:units("City")
	local aim = if #cities > 0 then cities[1]:tile() else target:tiles():values()[1]
	launcher:addGold(10_000_000)
	launcher.playerInfo.weapons = { megaNuke = true }
	if #launcher:units("Missile Silo") == 0 then
		local own = launcher:units("City")
		launcher:buildUnit("Missile Silo", if #own > 0 then own[1]:tile() else launcher:tiles():values()[1], {})
	end
	if noSams then
		for _, sam in game:units("SAM Launcher") do
			if sam:owner() ~= launcher then
				sam:delete(false)
			end
		end
	end
	local map = game:map()
	local function unowned(): number
		local n = 0
		for tile = 0, map:width() * map:height() - 1 do
			if map:isLand(tile) and not map:hasOwner(tile) then
				n += 1
			end
		end
		return n
	end
	local unownedBefore = unowned()
	local cost, m = 0, { inner = 0, outer = 0 }
	if bomb then
		cost = game:config():unitInfo(bomb).cost(game, launcher)
		m = game:config():nukeMagnitudes(bomb)
		game:addExecution(Construction.new(launcher, bomb, aim))
	end
	local launched, flight = nil, nil
	for tick = 1, 300 do
		runner:step()
		if bomb then
			local flying = #game:units(bomb) > 0
			if flying and launched == nil then
				launched = tick
			elseif not flying and launched and flight == nil then
				flight = tick - launched
			end
		end
	end
	return {
		launcher = launcher:name(),
		target = target:name(),
		sams = #target:units("SAM Launcher"),
		tiles = target:numTilesOwned(),
		troops = target:troops(),
		unowned = unowned() - unownedBefore,
		flight = flight,
		cost = cost,
		inner = m.inner,
		outer = m.outer,
	}
end

local function strike(atTick: number, noSams: boolean)
	local base = strikeOnce(atTick, nil, noSams)
	print(`strike at tick {atTick}: {base.launcher} fires at {base.target}'s first City{if noSams then ", other players' SAMs removed" else ""}; 30 s after launch, against no bomb:`)
	for _, bomb in { "Atom Bomb", "Mega Nuke", "Hydrogen Bomb" } do
		local r = strikeOnce(atTick, bomb, noSams)
		print(string.format(
			"  %-13s %4.2fM  r %3d/%3d  flight %s  target land %7d -> %7d (%+6.1f%%)  troops %8d -> %8d  land left unowned %+7d",
			bomb, r.cost / 1e6, r.inner, r.outer, if r.flight then `{r.flight} ticks` else "not landed",
			base.tiles, r.tiles, (r.tiles - base.tiles) / math.max(1, base.tiles) * 100,
			base.troops, r.troops, r.unowned - base.unowned
		))
	end
end

if mode == "strike" then
	strike(tonumber(process.args[2]) or 3000, process.args[3] == "nosams")
else
	reinforce(tonumber(process.args[2]) or 3, tonumber(process.args[3]) or 5000)
end
