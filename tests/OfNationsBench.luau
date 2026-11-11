-- lune run tests/OfNationsBench: server step cost with nations on the public
-- setup (full World, 400 tribes, the map's nations). Not part of the suite.
local process = require("@lune/process")
local Harness = require("./harness")
local Shared = Harness.shared()
local Runner = Harness.require(Shared.OpenFront.Runner)
local Maps = Harness.mount("src/maps", "OpenFrontMaps")

local runner = Runner.new({
	gameID = "bench-nations",
	nameBudgetMs = 4,
	mapFolder = Maps.World,
	gameConfig = {
		gameMap = "World",
		gameMapSize = "Normal",
		gameMode = "Free For All",
		gameType = "Public",
		difficulty = "Medium",
		bots = 400,
		nations = "default",
	},
})
local NATIONS = (process and process.args and process.args[1]) or "default"
runner.gameConfig.nations = NATIONS
local t0 = os.clock()
runner:start()
-- Time the name pass separately.
local namesMs = 0
local update = runner.names.update
runner.names.update = function(self: any, ...: any)
	local s = os.clock()
	local r = update(self, ...)
	namesMs += (os.clock() - s) * 1000
	return r
end
print(string.format("start: %.0f ms, %d nations", (os.clock() - t0) * 1000, #runner.game:nations()))
local samples = {}
for tick = 1, 1500 do
	local s = os.clock()
	runner:step()
	table.insert(samples, (os.clock() - s) * 1000)
	if tick % 300 == 0 then
		local window = table.move(samples, tick - 299, tick, 1, {})
		table.sort(window)
		print(string.format("ticks %d-%d: p50 %.1f ms, p95 %.1f ms, max %.1f ms; names %.1f ms/tick avg", tick - 299, tick, window[150], window[285], window[300], namesMs / 300))
		namesMs = 0
	end
end
