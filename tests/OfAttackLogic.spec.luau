-- OpenFront port, Phase A: EngineConfig.attackLogic against OpenFront's own
-- golden snapshot (tests/__snapshots__/AttackLogicGolden.test.ts.snap,
-- converted to tests/fixtures/openfront/attack-logic-golden.txt). The grids
-- below mirror AttackLogicGolden.test.ts; values are compared at the
-- snapshot's 6 significant digits, like its round().
return function(t)
	local EngineConfig = t.require("OpenFront.EngineConfig")
	local GameTypes = t.require("OpenFront.GameTypes")
	local PlayerType = GameTypes.PlayerType
	local TerrainType = GameTypes.TerrainType

	local config = EngineConfig.new({ difficulty = "Medium" }, false)

	local golden: { [string]: { number } } = {}
	local total = 0
	for _, line in string.split(t.readFile("tests/fixtures/openfront/attack-logic-golden.txt"), "\n") do
		local f = string.split(line, "|")
		if #f == 5 then
			golden[f[1] .. "|" .. f[2]] = { tonumber(f[3]) :: number, tonumber(f[4]) :: number, tonumber(f[5]) :: number }
			total += 1
		end
	end

	local function round(x: number): number
		return tonumber(string.format("%.6g", x)) :: number
	end

	local function defender(o: { [string]: any }): { [string]: any }
		return {
			type = o.type or PlayerType.Human,
			numTiles = o.numTiles,
			troops = o.troops,
			isTraitor = o.isTraitor or false,
			isDisconnectedTeammate = o.isDisconnectedTeammate or false,
		}
	end

	local checked = 0
	local function check(section: string, key: string, o: { [string]: any })
		local r = config:attackLogic({
			terrain = if o.terrain ~= nil then o.terrain else TerrainType.Plains,
			attackTroops = o.attackTroops,
			attacker = o.attacker or { type = PlayerType.Human, numTiles = 20_000 },
			defender = o.defender,
			defenderHasDefensePost = o.defenderHasDefensePost or false,
			falloutRatio = o.falloutRatio,
			borderSize = o.borderSize or 100,
		})
		local want = golden[section .. "|" .. key]
		if want == nil then
			error(`no golden value for {section} | {key}`, 2)
		end
		local got = { round(r.attackerTroopLoss), round(r.defenderTroopLoss), round(r.tickFraction) }
		local names = { "attackerLoss", "defenderLoss", "tickFraction" }
		for i = 1, 3 do
			if got[i] ~= want[i] then
				error(`{section} | {key} {names[i]}: expected {want[i]}, got {got[i]}`, 2)
			end
		end
		checked += 1
	end

	local TERRAINS = { "Plains", "Highland", "Mountain" }

	t.test("terrain x territory x troops grid", function()
		local section = "player vs player: terrain \u{D7} territory \u{D7} troops grid"
		for _, terrain in TERRAINS do
			for _, at in { 1_000, 50_000, 200_000 } do
				for _, dt in { 1_000, 50_000, 150_000, 400_000 } do
					for _, dtr in { 10_000, 100_000, 1_000_000 } do
						for _, atr in { 10_000, 100_000, 1_000_000 } do
							check(section, `{terrain} aTiles={at} dTiles={dt} dTroops={dtr} attack={atr}`, {
								terrain = TerrainType[terrain],
								attackTroops = atr,
								attacker = { type = PlayerType.Human, numTiles = at },
								defender = defender({ numTiles = dt, troops = dtr }),
							})
						end
					end
				end
			end
		end
	end)

	t.test("situational modifiers", function()
		local section = "player vs player: situational modifiers"
		local function base(extra: { [string]: any }?): { [string]: any }
			local d = { numTiles = 20_000, troops = 100_000 }
			for k, v in extra or {} do
				d[k] = v
			end
			return defender(d)
		end
		local function pvp(key: string, o: { [string]: any })
			o.attackTroops = 100_000
			o.defender = o.defender or base()
			check(section, key, o)
		end
		pvp("baseline", {})
		pvp("defender has defense post", { defenderHasDefensePost = true })
		pvp("no fallout", {})
		pvp("fallout 10%", { falloutRatio = 0.1 })
		pvp("fallout 100%", { falloutRatio = 1 })
		pvp("defender is traitor", { defender = base({ isTraitor = true }) })
		pvp("human attacks bot", { defender = base({ type = PlayerType.Bot }) })
		pvp("nation attacks bot", {
			attacker = { type = PlayerType.Nation, numTiles = 20_000 },
			defender = base({ type = PlayerType.Bot }),
		})
		pvp("bot attacks bot", {
			attacker = { type = PlayerType.Bot, numTiles = 20_000 },
			defender = base({ type = PlayerType.Bot }),
		})
		pvp("bot attacks human", { attacker = { type = PlayerType.Bot, numTiles = 20_000 } })
		pvp("disconnected teammate", { defender = base({ isDisconnectedTeammate = true }) })
		pvp("defense post + fallout + traitor (stacking)", {
			terrain = TerrainType.Mountain,
			defenderHasDefensePost = true,
			falloutRatio = 0.5,
			defender = base({ isTraitor = true }),
		})
	end)

	t.test("troop ratio clamps", function()
		for _, r in { 0.01, 0.1, 0.5, 0.6, 1, 2, 5, 7.5, 10, 100 } do
			check("player vs player: troop ratio clamps", `defenderTroops/attackTroops={r}`, {
				attackTroops = 100_000 / r,
				defender = defender({ numTiles = 20_000, troops = 100_000 }),
			})
		end
	end)

	t.test("large attacker overwhelming-push speed floor", function()
		for _, at in { 20_000, 300_000, 2_000_000 } do
			for _, r in { 0.5, 0.8, 0.9, 1, 1.5 } do
				check(
					"player vs player: large attacker overwhelming-push speed floor",
					`attackerTiles={at} defenderTroops/attackTroops={r}`,
					{
						attackTroops = 100_000 / r,
						attacker = { type = PlayerType.Human, numTiles = at },
						defender = defender({ numTiles = 20_000, troops = 100_000 }),
					}
				)
			end
		end
	end)

	t.test("large-territory curves", function()
		local section = "player vs player: large-territory curves"
		for _, s in { 1_000, 10_000, 50_000, 100_000, 100_001, 150_000, 200_000, 300_000, 500_000, 1_000_000 } do
			check(section, `attackerTiles={s}`, {
				attackTroops = 100_000,
				attacker = { type = PlayerType.Human, numTiles = s },
				defender = defender({ numTiles = 20_000, troops = 100_000 }),
			})
			check(section, `defenderTiles={s}`, {
				attackTroops = 100_000,
				defender = defender({ numTiles = s, troops = 100_000 }),
			})
		end
	end)

	t.test("player vs terra nullius", function()
		for _, terrain in TERRAINS do
			for _, kind in { PlayerType.Human, PlayerType.Bot } do
				for _, atr in { 100, 1_000, 10_000, 100_000, 1_000_000 } do
					for _, fallout in { 0, 0.5 } do
						check("player vs terra nullius", `{terrain} {kind} attack={atr} fallout={fallout}`, {
							terrain = TerrainType[terrain],
							attackTroops = atr,
							attacker = { type = kind, numTiles = 1_000 },
							falloutRatio = if fallout > 0 then fallout else nil,
						})
					end
				end
			end
		end
	end)

	t.test("border size", function()
		for _, dtr in { 1_000, 100_000, 10_000_000 } do
			for _, atr in { 1_000, 100_000, 10_000_000 } do
				for _, border in { 1, 10, 100, 1_000 } do
					check("border size", `dTroops={dtr} attack={atr} border={border}`, {
						attackTroops = atr,
						defender = defender({ numTiles = 20_000, troops = dtr }),
						borderSize = border,
					})
				end
			end
		end
		for _, border in { 1, 10, 100, 1_000 } do
			check("border size", `terraNullius border={border}`, { attackTroops = 1_000, borderSize = border })
		end
	end)

	t.test("extremes: territory and troop counts", function()
		for _, terrain in { "Plains", "Mountain" } do
			for _, at in { 100, 1_000_000, 5_000_000 } do
				for _, dt in { 100, 1_000_000 } do
					for _, dtr in { 0, 1, 1_000, 1_000_000, 10_000_000 } do
						for _, atr in { 1, 1_000, 1_000_000, 10_000_000 } do
							check(
								"extremes: territory and troop counts",
								`{terrain} aTiles={at} dTiles={dt} dTroops={dtr} attack={atr}`,
								{
									terrain = TerrainType[terrain],
									attackTroops = atr,
									attacker = { type = PlayerType.Human, numTiles = at },
									defender = defender({ numTiles = dt, troops = dtr }),
								}
							)
						end
					end
				end
			end
		end
	end)

	t.test("extremes: terra nullius", function()
		for _, at in { 100, 5_000_000 } do
			for _, atr in { 1, 10_000_000 } do
				check("extremes: terra nullius", `aTiles={at} attack={atr}`, {
					attackTroops = atr,
					attacker = { type = PlayerType.Human, numTiles = at },
				})
			end
		end
	end)

	t.test("impassable terrain throws", function()
		t.errors(function()
			config:attackLogic({
				terrain = TerrainType.Impassable,
				attackTroops = 1,
				attacker = { type = PlayerType.Human, numTiles = 20_000 },
				defenderHasDefensePost = false,
				borderSize = 100,
			})
		end)
	end)

	t.test("every golden value was checked", function()
		t.eq(checked, total, "golden rows covered")
	end)
end
