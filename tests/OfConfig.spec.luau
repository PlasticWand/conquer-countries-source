-- OpenFront port, Phase A: Config/EngineConfig formulas against values dumped
-- from OpenFront v0.35.2's own EngineConfig under vitest
-- (tests/fixtures/openfront/config-vectors.txt). Doubles compare exactly.
return function(t)
	local EngineConfig = t.require("OpenFront.EngineConfig")
	local GameTypes = t.require("OpenFront.GameTypes")
	local Util = t.require("OpenFront.Util")
	local UnitType = GameTypes.UnitType

	local lines = string.split(t.readFile("tests/fixtures/openfront/config-vectors.txt"), "\n")

	local function num(s: string): number
		if s == "Infinity" then
			return math.huge
		end
		return assert(tonumber(s), s)
	end

	local function same(actual: number, expected: number, label: string)
		if actual ~= expected then
			error(`{label}: expected {string.format("%.17g", expected)}, got {string.format("%.17g", actual)}`, 2)
		end
	end

	local function fakePlayer(kind: string, tiles: number, troops: number, cityLevels: { number }, owned: { [string]: number }?)
		local own = owned or {}
		return {
			type = function()
				return kind
			end,
			numTilesOwned = function()
				return tiles
			end,
			troops = function()
				return troops
			end,
			gold = function()
				return 1234567
			end,
			isLobbyCreator = function()
				return false
			end,
			units = function(_, unitType: string)
				local out = {}
				if unitType == UnitType.City then
					for _, l in cityLevels do
						table.insert(out, {
							isUnderConstruction = function()
								return false
							end,
							level = function()
								return l
							end,
						})
					end
				end
				return out
			end,
			unitsOwned = function(_, unitType: string)
				return own[unitType] or 0
			end,
			unitsConstructed = function(_, unitType: string)
				return own[unitType] or 0
			end,
		}
	end

	local configs = {}
	local function config(difficulty: string): any
		configs[difficulty] = configs[difficulty] or EngineConfig.new({ difficulty = difficulty, gameType = "Public", bots = 400 }, false)
		return configs[difficulty]
	end

	t.test("troop cap, growth, start values and spawn phase match OpenFront", function()
		local n = 0
		for _, line in lines do
			local f = string.split(line, " ")
			if f[1] == "troop" then
				local c = config(f[2])
				local cities = if f[6] == "2" then { 1, 3 } else {}
				local p = fakePlayer(f[3], num(f[4]), num(f[5]), cities)
				same(c:maxTroops(p), num(f[7]), line .. " maxTroops")
				same(c:troopIncreaseRate(p), num(f[8]), line .. " troopIncreaseRate")
				n += 1
			elseif f[1] == "start" then
				local c = config(f[2])
				same(c:startManpower({ playerType = f[3], isLobbyCreator = false }), num(f[4]), line)
				same(c:startingGold({ playerType = f[3] }), num(f[5]), line)
				same(c:goldAdditionRate(fakePlayer(f[3], 1, 1, {})), num(f[6]), line)
			elseif f[1] == "spawnturns" then
				t.eq(config(f[2]):numSpawnPhaseTurns(), num(f[3]), line)
			end
		end
		t.ok(n >= 700, `troop rows checked: {n}`)
	end)

	t.test("unit costs, trade, trains, nukes, SAM range and win share match OpenFront", function()
		local c = EngineConfig.new({ difficulty = "Medium" }, false)
		local ot = EngineConfig.new({ difficulty = "Medium", overtime = { enabled = true } }, false)
		local game = {
			mirvsLaunched = function()
				return 2
			end,
		}
		local seen: { [string]: number } = {}
		for _, line in lines do
			local f = string.split(line, " ")
			local kind = f[1]
			if kind == "cost" then
				local u = string.gsub(f[2], "_", " ")
				local owned = { [u] = num(f[3]), [UnitType.Factory] = if u == UnitType.Port then 1 else 0 }
				same(c:unitInfo(u).cost(game, fakePlayer("HUMAN", 10, 10, {}, owned)), num(f[4]), line)
			elseif kind == "tradegold" then
				same(c:tradeShipGold(num(f[2]), fakePlayer("HUMAN", 1, 1, {})), num(f[3]), line)
			elseif kind == "traderate" then
				same(c:tradeShipSpawnRate(num(f[2]), num(f[3]), num(f[4])), num(f[5]), line)
			elseif kind == "traingold" then
				same(c:trainGold(f[2], num(f[3]), fakePlayer("HUMAN", 1, 1, {})), num(f[4]), line)
			elseif kind == "trainrate" then
				same(c:trainSpawnRate(num(f[2]), num(f[3])), num(f[4]), line)
			elseif kind == "nukedeath" then
				same(c:nukeDeathFactor(string.gsub(f[2], "_", " "), num(f[3]), num(f[4]), num(f[5])), num(f[6]), line)
			elseif kind == "samrange" then
				same(c:samRange(num(f[2])), num(f[3]), line)
			elseif kind == "wintiles" then
				same(c:percentageTilesOwnedToWin(num(f[2])), num(f[3]), line)
				same(ot:percentageTilesOwnedToWin(num(f[2])), num(f[4]), line .. " overtime")
			elseif kind == "hash" then
				local s = string.sub(f[2], 2, -2)
				same(Util.simpleHash(s), num(f[3]), line)
			end
			if kind ~= "troop" and kind ~= "start" and kind ~= "spawnturns" and kind ~= "" then
				seen[kind] = (seen[kind] or 0) + 1
			end
		end
		for _, kind in { "cost", "tradegold", "traderate", "traingold", "trainrate", "nukedeath", "samrange", "wintiles", "hash" } do
			t.ok((seen[kind] or 0) > 0, `fixture has {kind} rows`)
		end
	end)
end
