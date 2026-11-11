-- lune run scripts/bench-late [ticks]
-- The server tick through a long match, for before/after comparisons of sim
-- speed-ups (audit 2026-11). The bench-nukes World match (Medium nations, 400
-- tribes, one idle human) is played for `ticks` (default 9000, fifteen
-- minutes). Prints runner:step ms (mean, p95, worst) for every 1,500 ticks
-- and a fingerprint of the state at the end of each window (every tile's
-- owner, each player's troops and gold, every unit's type, tile and level):
-- a faster sim must print the same fingerprints.
-- Lune timings: relative, not Roblox server numbers. Run before and after
-- back to back with nothing else running.

local process = require("@lune/process")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local Runner = Harness.require(Shared.OpenFront.Runner)

local ticks = tonumber(process.args[1]) or 9000
local WINDOW = 1500
local Maps = Harness.mount("src/maps", "OpenFrontMaps")

local runner = Runner.new({
	gameID = "bench-nukes",
	mapFolder = Maps.World,
	gameConfig = {
		gameMap = "World",
		gameMode = "Free For All",
		gameType = "Singleplayer",
		difficulty = "Medium",
		bots = 400,
		nations = "default",
	},
})
runner:addHuman("1", "Idle")
runner:start()
local game = runner.game
local map = game:map()
for tile = map:width() * map:height() - 1, 0, -1 do
	if map:isLand(tile) and not map:isImpassable(tile) and not map:hasOwner(tile) then
		runner:intent("1", { type = "spawn", tile = tile })
		break
	end
end

local function fingerprint(): number
	local h = 0
	for t = 0, game:width() * game:height() - 1 do
		h = (h * 31 + game:ownerID(t)) % 2147483647
	end
	for _, p in game:allPlayers() do
		h = (h * 31 + math.floor(p:troops()) + math.floor(p:gold() % 1000003)) % 2147483647
	end
	for _, u in game:units() do
		h = (h * 31 + u:id() * 7 + u:tile() + u:level() * 13 + #u:type()) % 2147483647
	end
	return h
end

local total = 0
local window = {}
for tick = 1, ticks do
	local t = os.clock()
	runner:step()
	local ms = (os.clock() - t) * 1000
	total += ms
	table.insert(window, ms)
	if tick % WINDOW == 0 or tick == ticks then
		table.sort(window)
		local sum = 0
		for _, v in window do
			sum += v
		end
		print(string.format("ticks %5d..%5d: mean %6.1f ms  p95 %6.1f  worst %6.1f   units %4d  alive %3d  fingerprint %d", tick - #window + 1, tick, sum / #window, window[math.max(1, math.ceil(#window * 0.95))], window[#window], #game:units(), #game:players(), fingerprint()))
		window = {}
	end
end
print(string.format("%d ticks in %.0f s of stepping, mean %.1f ms", ticks, total / 1000, total / ticks))
