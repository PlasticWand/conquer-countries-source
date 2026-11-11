-- lune run scripts/fuzz-intents [atTick] [intents] [seed]
-- Can a player's request break a match? (audit 2026-11.) The server ends a
-- match whose step throws, so one bad intent that reaches an execution could
-- stop a public match for everyone. A full-size World public match (two
-- humans, Medium nations, 400 tribes, the Arsenal on, every weapon unlocked
-- for the humans) is played to atTick (default 1500). Then `intents`
-- (default 30000) random and hostile intents are sent through Runner.intent as
-- human "1": every intent type with valid, wrong-typed, out-of-range, NaN,
-- huge, negative, fractional and foreign values (other players' ids, units
-- and tiles). The match is stepped every 40 intents inside pcall; any thrown
-- step is printed with the intents queued for it. Also prints how long the
-- Query calls take (playerActions with buildables, buildPreview per unit).
-- Lune timings: relative, not Roblox server numbers.

local process = require("@lune/process")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local Runner = Harness.require(Shared.OpenFront.Runner)
local ArsenalUnits = Harness.require(Shared.OpenFront.ArsenalUnits)
local GameTypes = Harness.require(Shared.OpenFront.GameTypes)
local HumanProtection = Harness.require(Shared.OpenFront.HumanProtection)

local atTick = tonumber(process.args[1]) or 1500
local total = tonumber(process.args[2]) or 30000
local seed = tonumber(process.args[3]) or 1
local Maps = Harness.mount("src/maps", "OpenFrontMaps")

local weapons = {}
for _, key in ArsenalUnits.KEYS do
	weapons[key] = true
end
local config: { [string]: any } = {
	gameMap = "World",
	gameMapSize = "Normal",
	gameMode = "Free For All",
	gameType = "Public",
	difficulty = "Medium",
	bots = 400,
	nations = "default",
	donateGold = true,
	donateTroops = true,
	extraWeapons = true,
	autoSpawnUnplaced = true,
	boatFullRefund = true,
}
HumanProtection.enable(config)
local runner = Runner.new({ gameID = "fuzzmatch", mapFolder = Maps.World, gameConfig = config })
runner:addHuman("1", "Fuzz", nil, { weapons = weapons })
runner:addHuman("2", "Other", nil, { weapons = weapons })
runner:start()
local game = runner.game
local map = game:map()
local W, H = map:width(), map:height()
local n = W * H

local stepErrors = 0
local pendingLog: { string } = {}
local function describe(v: any, depth: number?): string
	if type(v) == "table" then
		if (depth or 0) > 1 then
			return "{...}"
		end
		local parts = {}
		for k, x in v do
			table.insert(parts, `{k}={describe(x, (depth or 0) + 1)}`)
			if #parts >= 8 then
				break
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return tostring(v)
end
local function step()
	local ok, err = pcall(runner.step, runner)
	if not ok then
		stepErrors += 1
		if stepErrors <= 12 then
			print(`STEP THREW at tick {game:ticks()}: {err}`)
			for _, line in pendingLog do
				print(`   queued: {line}`)
			end
		end
	end
	pendingLog = {}
end

for _ = 1, atTick do
	step()
end
local me = game:playerByClientID("1")
local other = game:playerByClientID("2")
print(`tick {game:ticks()}: fuzzing as {me:name()} (alive {me:isAlive()}, {me:numTilesOwned()} tiles); step errors so far {stepErrors}`)
me:addGold(50_000_000)

math.randomseed(seed)
local rng = {
	NextInteger = function(_, a: number, b: number): number
		return math.random(a, b)
	end,
	NextNumber = function(_): number
		return math.random()
	end,
}
local function pick<T>(list: { T }): T
	return list[rng:NextInteger(1, #list)]
end
local players = game:allPlayers()
local function anyId(): any
	local r = rng:NextInteger(1, 12)
	if r <= 6 then
		return pick(players):id()
	elseif r == 7 then
		return me:id()
	elseif r == 8 then
		return "AllPlayers"
	elseif r == 9 then
		return "zzzzzzzz"
	elseif r == 10 then
		return ""
	elseif r == 11 then
		return 12345678
	end
	return nil
end
local function anyTile(): any
	local r = rng:NextInteger(1, 14)
	if r <= 5 then
		return rng:NextInteger(0, n - 1)
	elseif r <= 8 then
		local tiles = (if rng:NextInteger(1, 2) == 1 then me else pick(players)):tiles():values()
		return if #tiles > 0 then pick(tiles) else 0
	elseif r == 9 then
		return -1
	elseif r == 10 then
		return n
	elseif r == 11 then
		return 0 / 0
	elseif r == 12 then
		return 1.5
	elseif r == 13 then
		return math.huge
	end
	return "7"
end
local function anyNumber(): any
	local r = rng:NextInteger(1, 12)
	if r <= 4 then
		return rng:NextNumber() * me:troops() * 2
	elseif r == 5 then
		return 0
	elseif r == 6 then
		return -5
	elseif r == 7 then
		return 0 / 0
	elseif r == 8 then
		return math.huge
	elseif r == 9 then
		return 1e300
	elseif r == 10 then
		return 0.0001
	elseif r == 11 then
		return "100"
	end
	return nil
end
local function anyUnitId(): any
	local r = rng:NextInteger(1, 10)
	local units = game:units()
	if r <= 6 and #units > 0 then
		return pick(units):id()
	elseif r == 7 then
		return -1
	elseif r == 8 then
		return 2 ^ 40
	elseif r == 9 then
		return 0 / 0
	end
	return 999999
end
local unitTypes = {}
for _, t in GameTypes.UnitType do
	table.insert(unitTypes, t)
end
table.insert(unitTypes, "Nope")
local kinds = {
	"spawn", "attack", "boat", "tile_action", "cancel_attack", "cancel_boat", "build_unit", "build_action", "upgrade_structure",
	"delete_unit", "move_warship", "allianceRequest", "breakAlliance", "allianceExtension", "allianceReject", "targetPlayer",
	"emoji", "donate_troops", "donate_gold", "embargo", "embargo_all", "reinforce", "quick_chat", "toggle_pause", "mark_disconnected", "bogus",
}
local accepted, rejected, threw = 0, 0, 0
for i = 1, total do
	local kind = pick(kinds)
	local unitIds: any = {}
	for _ = 1, rng:NextInteger(0, 4) do
		table.insert(unitIds, anyUnitId())
	end
	local attackIds = {}
	for _, a in me:outgoingAttacks() do
		table.insert(attackIds, a:id())
	end
	local intent: { [string]: any } = {
		type = kind,
		tile = anyTile(),
		dst = anyTile(),
		troops = anyNumber(),
		gold = anyNumber(),
		ratio = if rng:NextInteger(1, 4) == 1 then anyNumber() else rng:NextNumber(),
		targetID = anyId(),
		recipient = anyId(),
		requestor = anyId(),
		target = anyId(),
		attackID = if #attackIds > 0 and rng:NextInteger(1, 2) == 1 then pick(attackIds) else tostring(rng:NextInteger(0, 99999)),
		unitID = anyUnitId(),
		unitId = anyUnitId(),
		unitIds = if rng:NextInteger(1, 8) == 1 then "x" else unitIds,
		unit = pick(unitTypes),
		amount = if rng:NextInteger(1, 3) == 1 then anyNumber() else rng:NextInteger(1, 50),
		rocketDirectionUp = if rng:NextInteger(1, 5) == 1 then "up" else rng:NextInteger(1, 2) == 1,
		emoji = if rng:NextInteger(1, 4) == 1 then anyNumber() else rng:NextInteger(0, 60),
		action = pick({ "start", "stop", "x" }),
		quickChatKey = pick({ "greet.hello", "help.troops", "nope", "attack.attack" }),
		paused = rng:NextInteger(1, 2) == 1,
		isDisconnected = true,
	}
	local ok, a, _reason = pcall(runner.intent, runner, "1", intent)
	if not ok then
		threw += 1
		if threw <= 8 then
			print(`INTENT THREW: {a}  {describe(intent)}`)
		end
	elseif a then
		accepted += 1
		table.insert(pendingLog, describe(intent))
	else
		rejected += 1
	end
	if i % 40 == 0 then
		step()
		if i % 4000 == 0 then
			-- keep the fuzzer able to act
			me:addGold(50_000_000)
		end
	end
end
for _ = 1, 100 do
	step()
end
print(`sent {total}: accepted {accepted}, rejected {rejected}, intent threw {threw}; match steps that threw {stepErrors}; tick {game:ticks()}; fuzzer alive {me:isAlive()}, other alive {other:isAlive()}`)

-- Query costs, as a client could ask them (40 a second allowed).
local function time(label: string, fn: () -> ())
	local worst, sum, count = 0, 0, 0
	for _ = 1, 40 do
		local t = os.clock()
		local ok = pcall(fn)
		local d = (os.clock() - t) * 1000
		if ok then
			sum += d
			count += 1
			worst = math.max(worst, d)
		end
	end
	print(string.format("  %-44s mean %.2f ms  worst %.2f ms (%d ok)", label, if count > 0 then sum / count else 0, worst, count))
end
local big = nil
for _, p in game:players() do
	if p:type() == "NATION" and (big == nil or p:numTilesOwned() > big:numTilesOwned()) then
		big = p
	end
end
-- as the largest nation would ask (a late-game human's cost)
local asker = if me:isAlive() then "1" else nil
print(`query costs at tick {game:ticks()} for the fuzzer ({me:numTilesOwned()} tiles){if asker then "" else " (dead: actions only)"}:`)
local function someTile(): number
	return rng:NextInteger(0, n - 1)
end
time("playerActions(tile, buildables)", function()
	runner:playerActions("1", someTile(), nil, true)
end)
time("playerActions(other)", function()
	runner:playerActions("1", nil, big:smallID(), false)
end)
for _, unit in { "City", "Port", "Warship", "Atom Bomb", "Hydrogen Bomb", "Mega Nuke", "Scattershot", "Air Strike", "Railgun Shot", "Paratroopers", "Sabotage", "Field Works", "Coastal Battery", "Artillery" } do
	time(`buildPreview({unit})`, function()
		runner:buildPreview("1", someTile(), unit)
	end)
end
