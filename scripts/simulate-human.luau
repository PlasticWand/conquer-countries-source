-- lune run scripts/simulate-human [Map] [Difficulty] [seed] [maxTicks] [pace] [protection]
-- Is a solo match winnable at this difficulty? Plays a solo match exactly as
-- the server sets one up (OpenFrontServer.soloConfig: full size, 400 tribes,
-- the map's nations) with one HUMAN player, and lets OpenFront's own nation
-- AI (NationExecution) play that human: attacks, boats, cities, ports,
-- defences, alliances, nukes, with a human's troop rules. If that player
-- can't reach the win share, a first-time player won't either.
--   pace: "match" (the AI's own pace for this difficulty: Easy acts every
--   65-100 ticks, a casual player) or "sharp" (every 30-50 ticks, as an
--   Impossible nation: an attentive player).
--   protection: "on" (as the server plays it: HumanProtection), or "off"
--   (OpenFront's own rules).
-- Prints the player's land share (of the land that counts for the win),
-- rank and troops every 1500 ticks (2.5 min), and how it ended.

local process = require("@lune/process")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local OF = Shared.OpenFront
local Runner = Harness.require(OF.Runner)
local HumanProtection = Harness.require(OF.HumanProtection)
local NationExecution = Harness.require(OF.Executions.NationExecution)

local mapName = process.args[1] or "World"
local difficulty = process.args[2] or "Easy"
local seed = tonumber(process.args[3]) or 1
local maxTicks = tonumber(process.args[4]) or 36000
local pace = process.args[5] or "match"
local protection = process.args[6] or "on"

local Maps = Harness.mount("src/maps", "OpenFrontMaps")
local folder = (Maps :: any)[mapName]
assert(folder, `no map {mapName} in src/maps`)

local gameID = string.format("hum%05d", seed)
local gameConfig: { [string]: any } = {
		gameMap = mapName,
		gameMapSize = "Normal",
		gameMode = "Free For All",
		gameType = "Singleplayer",
		difficulty = difficulty,
		bots = 400,
		nations = "default",
		donateGold = false,
		donateTroops = false,
		infiniteGold = false,
		infiniteTroops = false,
		instantBuild = false,
		randomSpawn = false,
		extraWeapons = false,
}
if protection == "on" then
	HumanProtection.enable(gameConfig)
end
local runner = Runner.new({ gameID = gameID, mapFolder = folder, gameConfig = gameConfig })
runner:addHuman("sim-human", "Tester")
runner:start()
local game = runner.game
local human = game:playerByClientID("sim-human")
assert(human, "the human wasn't added")
local exec = NationExecution.new(gameID, { playerInfo = human:info(), spawnCell = nil })
game:addExecution(exec)

local paced = false
local started = os.clock()
local peak, peakAt = 0, 0
local wonAt: number? = nil
local lines = {}
local function share(): number
	local land = game:numLandTiles() - game:numTilesWithFallout()
	return if land > 0 then human:numTilesOwned() / land else 0
end
local function rank(): number
	local r = 1
	for _, p in game:players() do
		if p ~= human and p:numTilesOwned() > human:numTilesOwned() then
			r += 1
		end
	end
	return r
end
local tick = 0
while tick < maxTicks do
	local ok, err = pcall(runner.step, runner)
	if not ok then
		table.insert(lines, `ERROR at tick {game:ticks()}: {err}`)
		break
	end
	tick += 1
	if pace == "sharp" and not paced and exec.mg ~= nil and exec.attackRate ~= nil then
		exec.attackRate = exec.random:nextInt(30, 50)
		exec.attackTick = exec.random:nextInt(0, exec.attackRate)
		paced = true
	end
	local s = share()
	if s > peak then
		peak, peakAt = s, tick
	end
	if tick % 1500 == 0 then
		table.insert(lines, string.format("  %5.1f min  share %5.1f%%  rank %3d  troops %8d  %s", tick / 600, s * 100, rank(), math.floor(human:troops()), if human:isAlive() then "" else "DEAD"))
	end
	local w = game:getWinner()
	if w ~= nil then
		wonAt = tick
		break
	end
	if human:hasSpawned() and not human:isAlive() then
		break
	end
end
local winner = game:getWinner()
local who = if winner == nil then "none" elseif type(winner) == "table" and winner.id and winner:id() == human:id() then "THE PLAYER" else "a nation"
print(string.format("%s %s seed %d pace %s protection %s: winner %s%s; peak %.1f%% at %.1f min; alive %s; %.1f ms/tick",
	mapName, difficulty, seed, pace, protection, who, if wonAt then string.format(" at %.1f min", wonAt / 600) else "",
	peak * 100, peakAt / 600, tostring(human:isAlive()), (os.clock() - started) / math.max(tick, 1) * 1000))
for _, l in lines do
	print(l)
end
